// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import OSLog
import SwiftUI

#if os(macOS)
// Inside the guard: `Route` and its sections below compile for the phone too,
// and an AppKit import at the top of the file breaks that build.
import AppKit

struct RootView: View {
    private struct SidebarChatReadIdentity: Hashable {
        let folderID: String
        let model: ObjectIdentifier
        let session: UInt64
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var route: Route = .global(.home)
    @State private var showWorkSearch = false
    @State private var ecosystemSearchTerm = ""
    @State private var ecosystemNavigation = EcosystemNavigation.shared
    @State private var railAccountHovered = false
    @State private var mountedChatFolder: String?
    @State private var showingChatOverview = false
    @State private var chatStart = ChatStartDraft()
    @State private var chatStartAdd: (owner: ChatStartDraft.Owner, repositories: Set<String>)?
    @State private var mountedPullsFolder: String?
    @State private var model = InsightsModel()
    @State private var home = HomeModel()
    @State private var account = AccountModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pullToOpen: PendingPullOpen?
    @Environment(\.openURL) private var openURL
    @State private var teams = TeamStore(api: .live)
    @State private var workspaces = WorkspacesModel()
    @State private var pullCounts = PullCountStore.shared
    @State private var machines = MachinesModel()
    @State private var showingSetupTour = false
    @State private var showingHandleOffer = false
    @State private var ssh = SSHLibraryModel()
    #if os(macOS)
    @State private var sshSessions = SSHSessionsModel()
    @State private var deviceRequests = DeviceAccessRequests.shared
    @State private var notificationOpen = NotificationOpen.shared
    #endif
    @State private var automations = AutomationsModel()
    @State private var workflows = WorkflowsModel()
    @State private var todo = TodoModel()
    @State private var chat = ChatModel()
    #if os(macOS)
    @State private var repositoryOverview = RepositoryOverviewModel()
    #endif
    @State private var appUpdate = AppUpdateModel()
    @State private var connectivity = ConnectivityModel()
    @State private var connection = ConnectionModel()
    @State private var isInspectorPresented = true
    @AppStorage(ChatBrowserPreferences.opensLinksKey) private var opensChatLinksInBrowser = true
    @State private var pendingChatLink: PendingChatLink?
    // The three column widths are plain state, read once and written back on
    // change. As `@AppStorage` Doubles, every unrelated defaults write (a
    // draft, the last open chat) re-checked them and rebuilt the whole shell
    // three times per chat switch. Only this view ever sets them.
    @State private var browserPaneWidth = StoredWidth.read(StoredWidth.browserPane, default: 520)
    @State private var workbenchResize = DesktopWorkbenchResizeState()
    @State private var simulatorRequests: [String: SimulatorAttachmentIntent] = [:]
    @State private var desktopTerminalRequests: [String: DesktopTerminalIntent] = [:]
    @State private var pendingDesktopOpen: PendingDesktopOpen?
    @State private var desktopActionScope: WorkReference.Scope?
    @State private var desktopActionError: String?
    @State private var pendingSimulatorAttach: PendingSimulatorAttach?
    @State private var desktopWorkbench = DesktopWorkbenchSession()
    @State private var desktopTurnReviews: [String: ChatTurnReview] = [:]
    @State private var desktopCommitReviews: [String: String] = [:]
    @State private var workspaceBrowserURLs: [String: String] = [:]
    @State private var columnVisibilityChoice: NavigationSplitViewVisibility = .all
    @State private var sidebarWidth = StoredWidth.read(StoredWidth.sidebar, default: ShellMetrics.sidebarDefault)
    @State private var columnDrag = ShellColumnDrag()
    @State private var inspectorWidth = StoredWidth.read(StoredWidth.inspector, default: ShellMetrics.inspectorDefault)
    @State private var inspectorFits = false
    @State private var isOverlayVisible = false
    @State private var overlayHeldByPress = false
    @State private var isSidebarOverlayVisible = false
    @State private var isSidebarPinned = false
    /// Keep exact geometry available to actions without invalidating the whole
    /// shell for each pixel. Layout still receives AppKit's size proposals;
    /// only column fit changes need to rebuild the shell's view descriptions.
    private final class WindowWidthStorage {
        var value: CGFloat = 0
    }
    private struct WindowWidthSignature: Equatable {
        var isKnown: Bool
        var sidebarFits: Bool
        var inspectorFits: Bool
        var workbenchDocks: Bool
        var showsConversationActions: Bool
        var clampedWorkbenchWidth: CGFloat?
    }
    @State private var windowWidthStorage = WindowWidthStorage()
    @State private var windowWidthSignature: WindowWidthSignature?
    private var windowContentWidth: CGFloat { windowWidthStorage.value }
    private var windowContentWidthBinding: Binding<CGFloat> {
        Binding(get: { windowContentWidth }, set: { width in
            windowWidthStorage.value = width
            let workbenchCap = showsWorkspaceCompanion ? maximumWorkbenchWidth : nil
            let next = WindowWidthSignature(
                isKnown: width > 0,
                sidebarFits: sidebarColumnFits(
                    width: width, browserOpen: showsWorkspaceCompanion, persistedBrowser: browserPaneWidth
                ),
                inspectorFits: inspectorFits(at: width),
                workbenchDocks: hasDockedWorkbench,
                showsConversationActions: showsConversationToolbarActions,
                clampedWorkbenchWidth: workbenchCap.flatMap { $0 < browserPaneWidth ? $0 : nil }
            )
            if windowWidthSignature != next { windowWidthSignature = next }
        })
    }
    #if os(macOS)
    /// Window geometry reported by `WindowScreenObserver`. The shell lets
    /// SwiftUI apply the system safe area in both windowed and full-screen mode.
    @State private var isFullScreen = false
    @State private var isLiveResizing = false
    #endif
    @State private var pendingRunID: String?
    @State private var heatmapHover = HeatmapHoverState()
    #if os(macOS)
    @State private var terminals = TerminalsModel()
    @State private var workspacePendingRemove: WorkspaceFolder?
    @State private var worktreeProject: WorkspaceFolder?
    @State private var sharingProject: WorkspaceFolder?
    @State private var stoppingSharing: TeamStopSharingRequest?
    @State private var workspacePendingChatRemoval: WorkspaceFolder?
    @State private var sessionPendingClose: TerminalSession?
    @State private var expandedWorkspaces: Set<String> = []
    @State private var knownSidebarProjects: Set<String> = []
    @State private var sidebarSectionOrder = SidebarPreferences.shared.sectionOrder
    @State private var expandedSidebarSections = Set(SidebarPreferences.defaultOrder.filter {
        SidebarPreferences.shared.isExpanded("section:" + $0, default: true)
    })
    @State private var expandedChatHistories = SidebarPreferences.shared.expandedIDs("history:")
    @State private var projectsFilter = ""
    @State private var showingProjectsFilter = false
    @State private var projectsDisplay = SidebarPreferences.shared.projectsDisplay
    @State private var projectsSort = SidebarPreferences.shared.projectsSort
    @State private var chatListLimit = SidebarProjectsLayout.chatPageSize
    @State private var collapsedChatDays: Set<String> = []
    @State private var chatOrderHold = ChatOrderHold()
    @State private var lastSection: [String: WorkspaceSection] = [:]
    @State private var pins = PinnedWorkStore.shared
    @State private var savedWorkCatalog = DesktopSavedWorkCatalog()
    @State private var savedConversation: DesktopSavedConversation.Destination?
    @State private var savedFolder: WorkFolderCacheSettings.Destination?
    #if os(macOS)
    @State private var expandedSSHHosts = SidebarPreferences.shared.expandedIDs("server:")
    @State private var sshHostPendingClose: SSHHost?
    #endif
    @State private var lastSSHSection: SSHSection = .hosts(folder: nil)
    @State private var workspaceDropBeforeID: String?
    #endif
    @State private var launch = LaunchState()
    @State private var placeSettled = false

    var body: some View {
        #if DEBUG
        if DebugUIHooks.printsChanges { Self._printChanges() }
        #endif
        return ecosystemSession
            .onReceive(NotificationCenter.default.publisher(for: .toggleLeftSidebar)) { _ in
                guard launch.hostReady else { return }
                toggleLeftSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchWorkRequested)) { _ in
                guard launch.hostReady else { return }
                showWorkSearch = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleRightSidebar)) { _ in
                guard launch.hostReady, route.hasInspector else { return }
                toggleRightSidebar()
            }
            .onChange(of: workspaces.folders.map(\.id), initial: true) { _, ids in
                let incoming = Set(ids)
                for id in incoming.subtracting(knownSidebarProjects) {
                    if SidebarPreferences.shared.isExpanded("project:" + id, default: true) {
                        expandedWorkspaces.insert(id)
                    }
                }
                expandedWorkspaces.formIntersection(incoming)
                desktopWorkbench.retain(workspaces: incoming)
                desktopTurnReviews = desktopTurnReviews.filter { incoming.contains($0.key) }
                desktopCommitReviews = desktopCommitReviews.filter { incoming.contains($0.key) }
                workspaceBrowserURLs = workspaceBrowserURLs.filter { incoming.contains($0.key) }
                simulatorRequests = simulatorRequests.filter { incoming.contains($0.key) }
                desktopTerminalRequests = desktopTerminalRequests.filter { incoming.contains($0.key) }
                resolvePendingDesktopOpen()
                knownSidebarProjects = incoming
                guard let id = route.workspaceID, !ids.contains(id) else { return }
                lastSection[id] = nil
                expandedWorkspaces.remove(id)
                if let next = workspaces.selectedID, ids.contains(next) {
                    selectWorkspace(next, revealInSidebar: false)
                } else {
                    navigate(to: .global(.home))
                }
            }
            .onChange(of: model.selected) { _, selected in
                guard route.isGlobal(.insights), selected != nil else { return }
                isInspectorPresented = true
                if !inspectorFits {
                    isOverlayVisible = true
                    overlayHeldByPress = true
                }
            }
            .onChange(of: todo.selectionGeneration) { _, _ in
                guard route.hasInspector, todo.selectedCardID != nil else { return }
                isInspectorPresented = true
                if !inspectorFits {
                    isOverlayVisible = true
                    overlayHeldByPress = true
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                terminals.acknowledgeVisibleAttention()
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
                connection.reset()
                Task {
                    await BridgeLaunch.wait()
                    await account.load()
                    await home.refreshIfStale()
                    await appUpdate.checkAndInstall()
                }
                Task {
                    await BridgeLaunch.wait()
                    await workspaces.load()
                }
                Task {
                    await BridgeLaunch.wait()
                    await Bridge.nudgeTunnel(reconnect: true)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task {
                    await BridgeLaunch.wait()
                    await Bridge.nudgeTunnelOnForeground()
                }
            }
            .onChange(of: notificationOpen.request, initial: true) { _, request in
                guard request != nil else { return }
                openPendingNotification()
            }
            .onChange(of: workspaces.folders.map(\.id)) { _, _ in
                openEcosystemDestination()
                openPendingNotification()
                resolvePendingSimulatorAttach()
            }
            .onChange(of: terminals.sessions.map(\.id)) { _, _ in
                openPendingNotification()
            }
            // One accent for every control in the window. Set here so a toggle,
            // a segmented picker or a prominent button does not have to
            // remember it, and cannot come back as system blue when somebody
            // adds the next one. The AppKit half of the same decision is the
            // AccentColor colorset in the asset catalogue.
            .tint(Theme.accent)
            .environment(account)
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugUIHooks.routeRequested)) { note in
                guard let target = note.object as? String else { return }
                debugNavigate(target)
            }
            #endif
    }

    private var ecosystemSession: some View {
        liveSession
            .task(id: SimulatorWatchIdentity(route: route,
                owner: route.workspaceID.flatMap { WorkViewedChange.owner(folderID: $0) })) {
                await followStartedSimulators()
            }
            .onOpenURL { url in
                if let request = SimulatorAttachRequest(url: url) { openSimulator(request) }
                else if let request = DesktopOpenRequest(url: url) { openDesktop(request) }
                else { ecosystemNavigation.receive(url) }
            }
            .onChange(of: ecosystemNavigation.pending, initial: true) { _, _ in openEcosystemDestination() }
            .onChange(of: placeSettled) { _, _ in openEcosystemDestination(); resolvePendingDesktopOpen() }
            .onChange(of: workspaces.isLoading) { _, _ in openEcosystemDestination(); resolvePendingSimulatorAttach(); resolvePendingDesktopOpen() }
            .onChange(of: workspaces.hasLoadedDirectory) { _, _ in resolvePendingSimulatorAttach(); resolvePendingDesktopOpen() }
            .onChange(of: WorkSessionContext.shared.scope) { _, _ in
                openEcosystemDestination()
                resolvePendingSimulatorAttach()
                resolvePendingDesktopOpen()
                Task { await workspaces.load() }
            }
            .onChange(of: WorkSessionContext.shared.localHostIdentity) { _, _ in resolvePendingSimulatorAttach(); resolvePendingDesktopOpen() }
            .onChange(of: route) { _, _ in resolvePendingSimulatorAttach() }
            .alert(L10n.text("apple.desktop_actions.unavailable_title"), isPresented: Binding(
                get: { desktopActionError != nil }, set: { if !$0 { desktopActionError = nil } }
            )) {
                Button(L10n.text("common.close"), role: .cancel) { desktopActionError = nil }
            } message: { Text(desktopActionError ?? "") }
    }

    private struct SimulatorWatchIdentity: Hashable {
        let route: Route
        let owner: WorkReference?
    }

    private func followStartedSimulators() async {
        guard route.workspaceSection == .chat, let id = route.workspaceID,
              WorkDestinationResolver.route(folderID: id).peer == nil else { return }
        guard let owner = WorkViewedChange.owner(folderID: id) else { return }
        let preferenceKey = "simulator." + (BrowserHistory.key(for: owner) ?? id)
        let key = preferenceKey + ".follow"
        var tracker = SimulatorBootTracker()
        while !Task.isCancelled {
            if NSApp.isActive {
                do {
                    let devices = try await SimulatorInventory.shared.load()
                    guard !Task.isCancelled, WorkViewedChange.owner(folderID: id) == owner else { return }
                    let allowedAfter = UserDefaults.standard.double(forKey: preferenceKey + ".followAfter")
                    let follows = (UserDefaults.standard.object(forKey: key) as? Bool ?? true) && Date().timeIntervalSince1970 >= allowedAfter
                    if let device = tracker.observe(devices, follows: follows) {
                        simulatorRequests[id] = SimulatorAttachmentIntent(deviceID: device)
                        openWorkbench(.simulator, in: id)
                    }
                } catch { }
            }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

    #if DEBUG
    private func debugNavigate(_ target: String) {
        let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "overview":
            navigate(to: .workspacesOverview)
        case "ssh":
            openSSH(lastSSHSection)
        case "newchat":
            startNewChat(in: debugFolder(parts.count > 1 ? parts[1] : "0"))
        case "chat":
            guard let folder = debugFolder(parts.count > 1 ? parts[1] : "0") else { return }
            let index = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            openSection(.chat, in: folder.id)
            Task {
                for _ in 0..<60 {
                    if chat.folderID == folder.id, !chat.isLoading { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard chat.folderID == folder.id, chat.chats.indices.contains(index) else { return }
                await chat.select(chat.chats[index])
            }
        case "click":
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let rows = Array(visibleChatEntries.prefix(chatListLimit))
            guard rows.indices.contains(index) else { return }
            openChatEntry(rows[index])
        case "workspace":
            let key = parts.count > 1 ? parts[1] : "0"
            let folder = Int(key).flatMap { workspaces.folders.indices.contains($0) ? workspaces.folders[$0] : nil }
                ?? workspaces.folders.first { $0.name == key }
            guard let folder else { return }
            if parts.count > 2, let section = WorkspaceSection(rawValue: parts[2]) {
                openSection(section, in: folder.id)
            } else {
                selectWorkspace(folder.id)
            }
        case "inspector":
            switch parts.count > 1 ? parts[1] : "" {
            case "changes": workspaces.inspectorTab = .changes
            case "history": workspaces.inspectorTab = .history
            default: workspaces.inspectorTab = .files
            }
        case "pull", "askpull":
            guard let folder = debugFolder(parts.count > 1 ? parts[1] : "0"), parts.count > 2,
                  let number = UInt32(parts[2]),
                  let pull = chat.sidebarChats(in: folder.id).lazy.flatMap(\.pulls).first(where: { $0.number == number }) else { return }
            if parts[0] == "pull" {
                openPull(pull, from: folder, in: .here)
            } else {
                openPull(pull, from: folder)
            }
        case "review":
            guard let folder = debugFolder(parts.count > 1 ? parts[1] : "0"), let files = folder.git?.files else { return }
            let index = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            guard files.indices.contains(index) else { return }
            workspaces.focusWorkingTree(in: folder.id, path: files[index].path)
            openWorkbench(.changes, in: folder.id)
        default:
            if let section = parts.first.flatMap(GlobalSection.init(rawValue:)) {
                navigate(to: .global(section))
            }
        }
    }

    private func debugFolder(_ key: String) -> WorkspaceFolder? {
        Int(key).flatMap { workspaces.folders.indices.contains($0) ? workspaces.folders[$0] : nil }
            ?? workspaces.folders.first { $0.name == key }
    }
    #endif

    private var windowLayout: some View {
        ZStack {
            if launch.hostReady, placeSettled {
                mainChrome
            } else {
                LaunchSplashView(isFullScreen: isFullScreen)
            }
        }
        .environment(\.hostReady, launch.hostReady)
        .environment(\.openTeamChat) { share, workspace in
            teams.openSharedChat(id: share, workspace: workspace)
            navigate(to: .global(.team))
        }
        .task(id: teamAccountOwner) {
            await BridgeLaunch.wait()
            guard !Task.isCancelled else { return }
            await teams.bind(to: teamAccountOwner)
            await teams.refreshSelected()
        }
        .task(id: teams.selectionKey) { await teams.refreshSelected() }
        .sheet(item: $pullToOpen) { pending in
            PullOpenSheet(pull: pending.pull) { choice in
                pullToOpen = nil
                openPull(pending.pull, from: pending.folder, in: choice)
            }
        }
        #if os(macOS)
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await refreshSidebarPullMarks()
        }
        #endif
        .task(id: TeamAppPresenceKey(owner: teams.owner, active: scenePhase == .active && teams.phase == .ready, supported: teams.capabilities?.supportsAppPresence == true)) {
            await teams.watchAppPresence(keepsWatching: true, active: {
                !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
            })
        }
        .onChange(of: teams.owner) { sharingProject = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if route.isGlobal(.team) || teams.phase == .authorization { Task { await teams.reloadAfterChange() } }
            else { Task { await teams.refreshLocalProjects() } }
        }
        .task {
            await launch.prepare()
            await WorkSessionContext.shared.resolveLocalHostIdentity()
        }
        .task {
            await settleLaunchPlace()
        }
        .onChange(of: launch.hostReady) { _, ready in
            guard ready else { return }
            Task { @MainActor in
                applyWidth(for: windowContentWidth)
            }
        }
        // Cell frames are reported in this space, and the popover overlay is
        // positioned in the same space, so a frame and its card agree wherever
        // the window is. Applied to the split view's result via the ZStack
        // content above: the modifiers below still attach to that tree.
        // (coordinateSpace stays on the outer ZStack so Home's heatmap and
        // popover share one space once the splash is gone.)
        .coordinateSpace(name: HeatmapView.coordinateSpace)
        .environment(\.heatmapHover, heatmapHover)
        // The inspector decision follows the window's width, published by the
        // observer from resize notifications. That source is outside any layout
        // pass; a GeometryReader inside the split view is not, and a width
        // driven from it re-entered AppKit's constraint cycle while dragging.
        .onChange(of: windowWidthSignature) { _, _ in
            applyWidth(for: windowContentWidth)
        }
        .onChange(of: sidebarWidth) { _, width in
            StoredWidth.write(width, StoredWidth.sidebar)
            applyWidth(for: windowContentWidth)
        }
        .onChange(of: inspectorWidth) { _, width in
            StoredWidth.write(width, StoredWidth.inspector)
            applyWidth(for: windowContentWidth)
        }
        .onChange(of: columnVisibilityChoice) { _, _ in applyWidth(for: windowContentWidth) }
        .onChange(of: showsWorkspaceBrowser) { _, _ in applyWidth(for: windowContentWidth) }
        .onChange(of: browserPaneWidth) { _, width in
            StoredWidth.write(width, StoredWidth.browserPane)
            applyWidth(for: windowContentWidth)
        }
        .onAppear { chat.sidebarStep = { stepChatList($0) } }
        .task(id: needsEdgeWatcher) {
            if needsEdgeWatcher { await watchPointer() }
        }
    }

    private var sizedWindow: some View {
        windowLayout
        .onAppear {
            connectivity.start()
            connection.attach(connectivity)
            BridgeObserver.report = { method, peer, error in
                guard let plane = NetworkPlane.of(method: method) else { return }
                Task { @MainActor in
                    connection.note(plane: plane, peer: peer, failure: error)
                }
            }
            BridgeObserver.precheck = { method in
                guard NetworkGate.isOffline, NetworkPlane.of(method: method) != nil else {
                    return nil
                }
                return BridgeError.core(
                    code: "offline",
                    message: L10n.text("apple.rootview.this_device_is_offline.84b7cf97")
                )
            }
        }
        .onDisappear { connectivity.stop() }
        .background {
            WindowScreenObserver(
                contentWidth: windowContentWidthBinding,
                isFullScreen: $isFullScreen,
                isLiveResizing: $isLiveResizing
            )
        }
        .overlay {
            GeometryReader { proxy in
                HeatmapPopoverOverlay(model: home, hover: heatmapHover, windowSize: proxy.size)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                TransientToast(message: Bindable(AgentUpdateNotice.shared).message,
                               severity: AgentUpdateNotice.shared.severity)
                    .padding(Theme.Space.m)
                UsageKeychainNotice {
                    UserDefaults.standard.set("planLimits", forKey: "account.settingsPane")
                    navigate(to: .global(.account))
                }
            }
        }
        .onChange(of: isLiveResizing) { _, resizing in
            if resizing { heatmapHover.update(nil) }
        }
        .task(id: WorkSessionContext.shared.scope) {
            workspaceBrowserURLs = [:]
            simulatorRequests = [:]
            desktopTerminalRequests = [:]
            desktopActionError = nil
            desktopWorkbench = DesktopWorkbenchSession()
            desktopTurnReviews = [:]
            desktopCommitReviews = [:]
            pendingChatLink = nil
            worktreeProject = nil
            desktopActionScope = WorkSessionContext.shared.scope
            await BridgeLaunch.wait()
            resolvePendingSimulatorAttach()
            resolvePendingDesktopOpen()
            await savedWorkCatalog.observe(scope: WorkSessionContext.shared.scope)
        }
        .sheet(item: $sharingProject) { folder in
            TeamFolderShareView(store: teams, workspace: .init(id: folder.id, name: folder.name, path: folder.path), onManageTeams: {
                sharingProject = nil; teams.show(.overview); teams.select(nil); navigate(to: .global(.team))
            }, onOpen: { organization, repository, checkout in
                sharingProject = nil
                teams.openProject(repository, in: organization, checkout: checkout)
                navigate(to: .global(.team))
            }).frame(width: 580, height: 720)
        }
        .sheet(item: $worktreeProject) { folder in
            RemoteHostFeatureGate(feature: .worktrees, peer: folder.machineID, hostName: folder.machineLabel) {
                ProjectWorktreeSheet(folder: folder) { created in
                    worktreeProject = nil
                    let scope = WorkSessionContext.shared.scope
                    Task {
                        guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                        if let peer = folder.machineID {
                            workspaces.acceptRegisteredRemoteProject(created, peer: peer, label: folder.machineLabel)
                            selectWorkspace("remote:\(peer):\(created.id)")
                        } else {
                            await workspaces.loadLocal()
                            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                            selectWorkspace(created.id)
                        }
                    }
                }
            }.modalFrame(width: 580, height: 610)
        }
        .sheet(item: $savedConversation) { DesktopSavedConversation(destination: $0) }
        .sheet(item: $pendingChatLink) { link in
            ChatLinkOpenSheet(url: link.url, preferred: opensChatLinksInBrowser ? .tokenstat : .system,
                              onOpen: { destination, remember in
                pendingChatLink = nil
                guard link.scope == WorkSessionContext.shared.scope else { return }
                if remember { ChatBrowserPreferences.remember(destination) }
                if destination == .tokenstat {
                    openChatBrowser(link.url, workspaceID: link.workspaceID)
                } else {
                    NSWorkspace.shared.open(link.url)
                }
            }, onClose: { pendingChatLink = nil })
        }
        .sheet(item: $savedFolder) { destination in
            WorkFolderCacheSettings(destination: destination)
        }
        .sheet(isPresented: $showWorkSearch, onDismiss: { ecosystemSearchTerm = "" }) {
            DesktopWorkSearchPresentation(account: account, workspaces: workspaces, open: openSearchWork, initialQuery: ecosystemSearchTerm)
        }
        .sheet(isPresented: $workspaces.isAddSheetPresented, onDismiss: finishChatStartAdd) {
            AddWorkspaceSheet(model: workspaces, machines: account.account?.machines ?? [])
        }
        #if os(macOS)
        .sheet(item: $ssh.connectRequest) { host in
            SSHConnectForm(host: host, model: ssh) { session in
                sshSessions.adopt(
                    session,
                    startup: session.hostID.map { ssh.startupSnippets(for: $0) } ?? []
                )
                if let hostID = session.hostID {
                    navigate(to: .sshTerminals(host: hostID))
                }
            }
        }
        .sheet(item: $deviceRequests.asking) { request in
            DeviceAccessRequestSheet(request: request, model: deviceRequests)
        }
        .sheet(isPresented: $showingSetupTour, onDismiss: { SetupTourPreferences.markSeen() }) {
            SetupTour(
                signedIn: account.signedIn,
                remote: SetupTourRemote(allowed: machines.remoteReachAllowed,
                                        enabled: machines.status?.tunnel == true,
                                        set: { await machines.setTunnel($0) }),
                host: SetupTourHost(policy: account.hostPolicy,
                                    saving: account.isSavingHostPolicy,
                                    set: { await account.setAlwaysOnHost($0) },
                                    limitsShared: account.limitsSyncEnabled,
                                    setLimitsShared: { await account.setLimitsSync($0) }),
                onSignIn: { account.signIn() },
                onFinish: { showingSetupTour = false }
            )
            .modalFrame(width: 540, height: 600)
            .task { await machines.load() }
        }
        .task(id: "\(route.isGlobal(.home))-\(account.signedIn)") {
            SetupTourPreferences.noteLaunch()
            guard route.isGlobal(.home), account.signedIn else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, route.isGlobal(.home),
                  SetupTourPreferences.shouldShow(signedIn: account.signedIn) else { return }
            showingSetupTour = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatOpenSetupTour)) { _ in
            showingSetupTour = true
        }
        .modifier(HandleOffer(model: account,
                              ready: route.isGlobal(.home) && account.signedIn && !showingSetupTour,
                              showing: $showingHandleOffer))
        .gitSyncSheetHost()
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in Task { await deviceRequests.refresh() } }
        #endif

    }

    private var liveSession: some View {
        sizedWindow
            .task(id: route) {
                guard route.isGlobal(.insights) else { return }
                await model.load()
            }
            .onChange(of: route) { _, next in
                DiagnosticsLog.note("screen \(next.diagnosticName)")
                if case let .workspace(id: id, section: .chat) = next { desktopWorkbench.activate(in: id) }
                isOverlayVisible = false
                overlayHeldByPress = false
                applyScope(from: next)
                if next.isGlobal(.machines) {
                    machines.syncConnectedPeers(workspaces.connectedRemotePeerKeys)
                }
                guard next.isGlobal(.home) else { return }
                Task {
                    await BridgeLaunch.wait()
                    await home.refreshIfStale()
                }
            }
            .onChange(of: workspaces.front(in: route.workspaceID ?? "")) { _, front in
                syncRouteToFront(front)
            }
            .onChange(of: workspaces.connectedRemotePeerKeys) { _, peers in
                machines.syncConnectedPeers(peers)
            }
            .onChange(of: account.syncGeneration) { _, _ in
                refreshAfterSync()
            }
            .onReceive(NotificationCenter.default.publisher(for: .tokenstatDidSync)) { _ in
                refreshAfterSync()
            }
            .onReceive(NotificationCenter.default.publisher(for: .archiveDidChange)) { _ in
                model.reload()
            }
            .task(id: home.isArchiveReady) {
                await BridgeLaunch.wait()
                guard home.isArchiveReady else { return }
                await warmSecondarySurfaces()
            }
            #if os(macOS)
            .task(id: WorkSessionContext.shared.generation) {
                ssh.deactivate()
                sshSessions.deactivate()
                let library = SSHLibraryModel(ownerScope: WorkSessionContext.shared.scope)
                let sessions = SSHSessionsModel(isOwnerCurrent: { library.ownership.claim() != nil })
                ssh = library; sshSessions = sessions
                terminals.sshSessions = sessions
                await BridgeLaunch.wait()
                guard !Task.isCancelled else { return }
                await library.ensureLoaded(vaultTier: SSHLibraryModel.paidTier(for: machines.vaultTier))
                guard !Task.isCancelled else { return }
                await sessions.watch()
            }
            .onAppear {
                account.signInPresenter = { MacWebAuth.shared.start($0) }
                account.signInDismisser = { MacWebAuth.shared.cancel() }
            }
            #endif
            .task {
                await BridgeLaunch.wait()
                await automations.load()
                while !Task.isCancelled {
                    let interval: Duration = automations.runs.contains(where: \.isRunning)
                        ? .seconds(2)
                        : .seconds(12)
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await automations.refreshList()
                }
            }
            .task {
                await BridgeLaunch.wait()
                await workflows.load()
                while !Task.isCancelled {
                    let interval: Duration = workflows.runs.contains(where: \.isLive)
                        ? .seconds(2)
                        : .seconds(12)
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await workflows.refreshList()
                }
            }
            .task {
                await BridgeLaunch.wait()
                await todo.load()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    await todo.refreshCounts()
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await BridgeLaunch.wait()
                await account.load()
            }
            .task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await appUpdate.checkAndInstall()
            }
            .task {
                await BridgeLaunch.wait()
                let localLoaded = await workspaces.loadLocal()
                await withTaskGroup(of: Void.self) { group in
                    if !localLoaded {
                        group.addTask { @MainActor in
                            var wait: Duration = .milliseconds(500)
                            repeat {
                                try? await Task.sleep(for: wait)
                                guard !Task.isCancelled else { return }
                                wait = min(wait * 2, .seconds(10))
                            } while await !workspaces.loadLocal()
                        }
                    }
                    group.addTask { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        await workspaces.loadRemote()
                        await workspaces.watchPeers()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidConnect)) { note in
                if let key = note.object as? String {
                    machines.markConnected(key)
                    if note.userInfo?["workspaceFoldersReady"] as? Bool != true {
                        workspaces.reconnect(peer: key)
                    }
                } else {
                    Task {
                        await BridgeLaunch.wait()
                        await workspaces.loadRemote()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidDisconnect)) { note in
                if let key = note.object as? String {
                    machines.markDisconnected(key)
                    workspaces.disconnect(peer: key)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePeerBecameUnreachable)) { note in
                if let key = note.object as? String {
                    machines.markDisconnected(key)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await BridgeLaunch.wait()
                await terminals.load()
                await terminals.watch()
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .addWorkspaceRequested) {
                    workspaces.requestAdd()
                }
            }
    }

    private var detailUsesTitlebar: Bool {
        !isFullScreen && (ShellMetrics.usesGlass || showsSidebar)
    }

    private var usesUnifiedChrome: Bool {
        ShellMetrics.usesGlass
    }

    private var chromeHeaderInset: CGFloat {
        usesUnifiedChrome ? ShellMetrics.headerHeight : 0
    }

    private var hasDockedWorkbench: Bool {
        showsWorkspaceCompanion && browserFitsBesideWorkspace
    }

    private var showsConversationToolbarActions: Bool {
        windowContentWidth <= 0 || windowContentWidth - leftChromeWidth >= 600
    }

    private var mainChrome: some View {
        HStack(spacing: 0) {
            leftChrome.zIndex(1)
            LiveSteppedDetail(drag: columnDrag) { detailColumn }
                .environment(\.detailChromeToggles, detailChromeToggles)
                .environment(\.desktopChromeJoined, usesUnifiedChrome)
                .ignoresSafeArea(.container, edges: detailUsesTitlebar ? .top : [])
        }
        .background(alignment: .topLeading) {
            if usesUnifiedChrome {
                DesktopChromeSurface(sidebarWidth: leftChromeWidth, drag: showsSidebar ? columnDrag : nil,
                                     storedSidebar: sidebarWidth, isFullScreen: isFullScreen)
                    .ignoresSafeArea(.container, edges: detailUsesTitlebar ? .top : [])
            }
        }
        .environment(\.isWindowLiveResizing, isLiveResizing)
        .transaction { if isLiveResizing { $0.animation = nil; $0.disablesAnimations = true } }
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .environment(\.openURL, OpenURLAction { url in
            if let request = DesktopOpenRequest(url: url) {
                openDesktop(request)
                return .handled
            }
            if let request = SimulatorAttachRequest(url: url) {
                openSimulator(request)
                return .handled
            }
            guard route.workspaceSection == .chat,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let id = route.workspaceID else { return .systemAction }
            switch ChatBrowserPreferences.savedDestination() {
            case nil:
                pendingChatLink = PendingChatLink(url: url, workspaceID: id, scope: WorkSessionContext.shared.scope)
            case .tokenstat:
                openChatBrowser(url, workspaceID: id)
            case .system:
                return .systemAction
            }
            return .handled
        })
    }

    private struct PendingChatLink: Identifiable {
        let id = UUID()
        let url: URL
        let workspaceID: String
        let scope: WorkReference.Scope?
    }

    private func openChatBrowser(_ url: URL, workspaceID: String) {
        workspaceBrowserURLs[workspaceID] = url.absoluteString
        openWorkbench(.browser, in: workspaceID)
    }

    private struct PendingDesktopOpen {
        let request: DesktopOpenRequest
        let scope: WorkReference.Scope?
    }
    private func openDesktop(_ request: DesktopOpenRequest) {
        desktopActionError = nil
        pendingDesktopOpen = PendingDesktopOpen(request: request, scope: WorkSessionContext.shared.scope)
        resolvePendingDesktopOpen()
    }
    private func resolvePendingDesktopOpen() {
        guard let pending = pendingDesktopOpen else { return }
        if let scope = pending.scope, scope != WorkSessionContext.shared.scope { pendingDesktopOpen = nil; return }
        guard placeSettled, let scope = WorkSessionContext.shared.scope,
              desktopActionScope == scope else { return }
        let request = pending.request
        guard workspaces.folders.contains(where: { $0.id == request.workspaceID }) else {
            guard workspaces.hasLoadedDirectory, !workspaces.isLoading else { return }
            pendingDesktopOpen = nil
            desktopActionError = L10n.text("apple.desktop_actions.project_missing")
            return
        }
        guard WorkViewedChange.owner(folderID: request.workspaceID) != nil else { return }
        pendingDesktopOpen = nil
        let id = request.workspaceID
        if route.workspaceID != id || route.workspaceSection != .chat { navigate(to: .workspace(id: id, section: .chat)) }
        switch request.tool {
        case .changes:
            desktopTurnReviews[id] = nil; desktopCommitReviews[id] = request.commitID
        case .browser:
            if let url = request.browserURL { workspaceBrowserURLs[id] = url.absoluteString }
        case .terminal:
            if request.sessionID != nil || request.newTerminal {
                desktopTerminalRequests[id] = DesktopTerminalIntent(sessionID: request.sessionID, newTerminal: request.newTerminal)
            } else { desktopTerminalRequests[id] = nil }
        case .inspector:
            if let tab = request.inspectorTab {
                workspaces.chatInspectorShowsSettings = false
                switch tab {
                case .files: workspaces.inspectorTab = .files
                case .changes: workspaces.inspectorTab = .changes
                case .history: workspaces.inspectorTab = .history
                }
            }
        case .simulator: break
        }
        openWorkbench(request.tool, in: id)
    }

    private func openSimulator(_ request: SimulatorAttachRequest) {
        pendingSimulatorAttach = PendingSimulatorAttach(request: request, scope: WorkSessionContext.shared.scope)
        resolvePendingSimulatorAttach()
    }

    private struct PendingSimulatorAttach {
        let request: SimulatorAttachRequest
        let scope: WorkReference.Scope?
    }

    private func resolvePendingSimulatorAttach() {
        guard let pending = pendingSimulatorAttach else { return }
        if let scope = pending.scope, scope != WorkSessionContext.shared.scope {
            pendingSimulatorAttach = nil
            return
        }
        guard let id = pending.request.workspaceID ?? route.workspaceID else { return }
        guard workspaces.folders.contains(where: { $0.id == id }) else {
            guard pending.request.workspaceID != nil, workspaces.hasLoadedDirectory, !workspaces.isLoading else { return }
            pendingSimulatorAttach = nil
            desktopActionError = L10n.text("apple.desktop_actions.project_missing")
            return
        }
        guard WorkViewedChange.owner(folderID: id) != nil else { return }
        pendingSimulatorAttach = nil
        guard WorkDestinationResolver.route(folderID: id).peer == nil else { return }
        simulatorRequests[id] = SimulatorAttachmentIntent(deviceID: pending.request.deviceID)
        if route.workspaceID != id { navigate(to: .workspace(id: id, section: .chat)) }
        openWorkbench(.simulator, in: id)
    }

    /// The rail and the sidebar, on one surface.
    ///
    /// Glass on macOS 26 and later, where the panel floats inside the window
    /// edges with the traffic lights inside it, the way the system's own
    /// sidebars do. Runs up through the titlebar band on every system, because
    /// that band is where the lights are and they belong to this surface.
    private var leftChrome: some View {
        HStack(spacing: 0) {
            rail
            if showsSidebar {
                sidebar
                    .modifier(LiveColumnWidth(drag: columnDrag, column: .sidebar, stored: sidebarWidth))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .padding(ShellMetrics.panelInset)
        .background {
            if !usesUnifiedChrome { Theme.sidebar }
        }
        .overlay(alignment: .trailing) {
            if showsSidebar {
                ColumnResizeHandle(
                    side: .leading,
                    width: $sidebarWidth,
                    liveWidth: { columnDrag.sidebar }, setLiveWidth: { columnDrag.sidebar = $0 },
                    range: sidebarDragRange,
                    showsLine: !usesUnifiedChrome,
                    help: L10n.text("apple.rootview.drag_to_resize_the_sidebar_double_click_to.8259cca6")
                )
                .padding(.top, chromeHeaderInset)
                .offset(x: 3)
            } else {
                ThemeRule.vertical.padding(.top, chromeHeaderInset)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    static func sidebarChatRowID(_ conversationID: String) -> String {
        "sidebar-chat-\(conversationID)"
    }

    private var currentSidebarWidth: CGFloat {
        CGFloat(sidebarWidth)
    }

    private var leftChromeWidth: CGFloat {
        let rail = ShellMetrics.railWidth + (ShellMetrics.usesGlass ? ShellMetrics.panelInset * 2 : 6)
        return rail + (showsSidebar ? currentSidebarWidth : 0)
    }

    private var currentInspectorWidth: CGFloat {
        CGFloat(inspectorWidth)
    }

    private var rail: some View {
        VStack(spacing: 3) {
            ForEach(RailPlace.allCases) { place in
                RailButton(
                    place: place,
                    isSelected: RailPlace.of(route) == place,
                    badge: railBadge(place)
                ) { openRail(place) }
            }
            Spacer(minLength: Theme.Space.s)
            railAccount
        }
        .padding(.top, isFullScreen ? 0 : ShellMetrics.titleBand - ShellMetrics.panelInset + 4)
        .padding(.bottom, Theme.Space.m)
        .frame(width: ShellMetrics.railWidth + (ShellMetrics.usesGlass ? 0 : 6))
    }

    private func railBadge(_ place: RailPlace) -> Bool {
        switch place {
        case .automations:
            return automations.runs.contains(where: \.isRunning) || workflows.runs.contains(where: \.isLive)
        #if os(macOS)
        case .ssh:
            return !sshSessions.sessions.isEmpty && RailPlace.of(route) != .ssh
        case .devices:
            return deviceRequests.asking != nil
        #endif
        default:
            return false
        }
    }

    private func openRail(_ place: RailPlace) {
        switch place {
        case .home: navigate(to: .global(.home))
        case .projects: navigate(to: .workspacesOverview)
        case .tasks: navigate(to: .global(.todo))
        case .notes: navigate(to: .global(.notes))
        case .automations:
            if !route.isGlobal(.workflows) { navigate(to: .global(.automations)) }
        case .insights: navigate(to: .global(.insights))
        case .devices: navigate(to: .global(.machines))
        case .team: navigate(to: .global(.team))
        case .ssh:
            #if os(macOS)
            openSSH(lastSSHSection)
            #endif
        }
    }

    /// The account picture, with the account menu behind it.
    ///
    /// A real `NSMenu` over an ordinary view. A macOS `Menu` does not host a
    /// custom label, it rebuilds it: the picture was lifted out and repainted
    /// across the whole control, and the name slid under it. An ordinary view
    /// with `NativeMenuTrigger` over it stays exactly as drawn.
    private var railAccount: some View {
        ZStack {
            Avatar(
                url: account.account?.avatar,
                name: account.account?.title,
                handle: account.account?.handle,
                size: 28
            )
            .frame(width: 40, height: 40)
            .overlay {
                if let tier = railAccountTier, BadgeShape(tier: tier) != nil {
                    Circle().strokeBorder(Theme.border, lineWidth: 1)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    AngularGradient(
                                        colors: [Theme.accent, Theme.secondary, Theme.accent],
                                        center: .center
                                    ),
                                    lineWidth: 1.5
                                )
                                .rotationEffect(.degrees(railAccountHovered && !reduceMotion ? 120 : 0))
                                .opacity(railAccountHovered ? 1 : 0)
                                .shadow(color: Theme.secondary.opacity(railAccountHovered ? 0.22 : 0), radius: 3)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: railAccountHovered)
                        }
                        .frame(width: 34, height: 34)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let tier = railAccountTier, BadgeShape(tier: tier) != nil {
                    TierMark(tier: tier, size: 11)
                        .frame(width: 18, height: 18)
                        .background(Theme.sidebar, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                }
            }
            .overlay(alignment: .topTrailing) {
                if account.isSyncing {
                    Circle().fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Theme.sidebar, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)
            #if os(macOS)
            NativeMenuTrigger(items: { accountMenuItems }, accessibilityLabel: railAccountLabel)
            #endif
        }
        .frame(width: 40, height: 40)
        .onHover { railAccountHovered = $0 }
        .help(railAccountLabel)
    }

    private var teamAccountOwner: TeamAccountOwner? {
        let context = WorkSessionContext.shared
        guard account.signedIn, let scope = context.scope, scope.kind == .account,
              let session = context.accountSession, !session.isEmpty else { return nil }
        return TeamAccountOwner(scope: scope, generation: context.generation, session: session, personId: account.account?.accountId)
    }

    private var railAccountTier: String? {
        guard account.signedIn,
              let tier = account.account?.tier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tier.isEmpty else { return nil }
        return tier.lowercased()
    }

    private var railAccountLabel: String {
        guard account.signedIn else { return L10n.text("apple.rootview.account_sign_in_to_tokenstat.7888d723") }
        let name = account.account?.title ?? L10n.text("apple.rootview.signed_in.ca566c89")
        guard let tier = railAccountTier else { return L10n.text("apple.rootview.account_0.1342b321", "\(name)") }
        return L10n.text("apple.rootview.account_0_1_plan.75429042", "\(name)", "\(PlanName.title(tier))")
    }

    private var detailChromeToggles: DetailChromeToggles {
        DetailChromeToggles(
            leftSidebar: AnyView(leftSidebarToolbarButton),
            rightInspector: route.hasInspector
                ? AnyView(rightInspectorToolbarButton)
                : nil,
            search: nil,
            sectionTabs: sectionTabs,
            title: pageTitle,
            usesTitlebar: detailUsesTitlebar
        )
    }

    private var pageTitle: String? {
        switch route {
        case .global(.home), .global(.insights), .global(.automations), .global(.workflows), .global(.account):
            return nil
        case let .global(section): return section.label
        case .workspacesOverview: return L10n.text("apple.rootview.all_projects.4b87271b")
        default: return nil
        }
    }

    private var sectionTabs: AnyView? {
        if let projectHeader { return AnyView(projectHeader) }
        switch route {
        case .global(.automations), .global(.workflows):
            return AnyView(ChromeTabStrip(
                tabs: [
                    ChromeTab(id: GlobalSection.automations.rawValue, label: L10n.text("common.automations"), symbol: "bolt"),
                    ChromeTab(id: GlobalSection.workflows.rawValue, label: L10n.text("common.workflows"),
                              symbol: GlobalSection.workflows.symbol),
                ],
                selected: route.globalSection?.rawValue
            ) { id in
                if let section = GlobalSection(rawValue: id) { navigate(to: .global(section)) }
            }
            .equatable())
        #if os(macOS)
        case .ssh, .sshTerminals:
            return AnyView(ChromeTabStrip(
                tabs: SSHSection.rows.map { ChromeTab(id: $0.id, label: $0.label, symbol: $0.symbol) },
                selected: route.sshSection?.row.id,
                primary: 4
            ) { id in
                if let section = SSHSection.rows.first(where: { $0.id == id }) { openSSH(section) }
            }
            .equatable())
        #endif
        default:
            return nil
        }
    }

    private var projectHeader: ProjectHeader? {
        guard let id = route.workspaceID,
              let folder = workspaces.folders.first(where: { $0.id == id }) else { return nil }
        var branch: AnyView?
        if let git = folder.git, git.isRepo {
            #if os(macOS)
            let openWorktrees: (() -> Void)? = { worktreeProject = folder }
            #else
            let openWorktrees: (() -> Void)? = nil
            #endif
            branch = AnyView(AlignmentShieldLayout { ViewThatFits(in: .horizontal) {
                BranchChip(workspaceID: folder.id, git: git, model: workspaces,
                           onWorktrees: openWorktrees) {
                    await workspaces.refresh()
                }
                .fixedSize()
                BranchChip(workspaceID: folder.id, git: git, compact: true, model: workspaces,
                           onWorktrees: openWorktrees) {
                    await workspaces.refresh()
                }
                .fixedSize()
            } })
        }
        return ProjectHeader(
            folder: folder,
            selected: route.workspaceSection,
            branch: branch,
            count: { section in
                switch section {
                case .sessions, .changes, .pulls, .todo: return count(of: section, in: folder)
                default: return nil
                }
            }
        ) { section in
            openSection(section, in: folder.id) {
                if section == .chat { showingChatOverview = false }
            }
        }
    }

    private var leftSidebarToolbarButton: some View {
        SidebarToggleButton(
            edge: .leading,
            isOpen: isLeftSidebarOpen,
            action: toggleLeftSidebar,
            help: isLeftSidebarOpen
                ? L10n.text("apple.rootview.hide_sidebar_b.630ce4d6")
                : L10n.text("apple.rootview.show_sidebar_b.4de58db8")
        )
    }

    private var rightInspectorToolbarButton: some View {
        HStack(spacing: 2) {
            if supportsWorkspaceBrowser {
                if showsConversationToolbarActions {
                    ToolbarIconButton(systemImage: ActionIcon.compare.symbol,
                                      help: L10n.text("apple.workbench.review_beside_chat"),
                                      isAccent: workbenchState.isPresented && workbenchState.selected == .changes,
                                      action: openWorkingTreeBesideChat)
                    ToolbarIconButton(systemImage: "globe",
                                      help: L10n.text("apple.rootview.browser_open_a_web_preview_beside_this_pro.fc5d34f3"),
                                      isAccent: showsWorkspaceBrowser) { openWorkbench(.browser) }
                        .accessibilityLabel(L10n.text("common.browser"))
                    ToolbarIconButton(systemImage: "terminal",
                                      help: L10n.text("apple.rootview.shell_or_agent_beside_this_chat.2a4ad70d"),
                                      isAccent: showsWorkspaceTerminal) { openWorkbench(.terminal) }
                        .accessibilityLabel(L10n.text("apple.rootview.terminal_beside_chat.40991a3f"))
                } else {
                    ToolbarMenuButton(systemImage: "rectangle.split.2x1",
                                      help: L10n.text("apple.workbench.add_tool")) {
                        ForEach(DesktopWorkbenchState.Tool.allCases) { tool in
                            Button {
                                if tool == .changes { openWorkingTreeBesideChat() }
                                else { openWorkbench(tool) }
                            } label: {
                                Label(tool.title, systemImage: tool.symbol)
                            }
                        }
                    }
                }
            }
            SidebarToggleButton(
                edge: .trailing,
                isOpen: supportsWorkspaceBrowser ? showsWorkspaceCompanion : isRightSidebarOpen,
                action: toggleRightSidebar,
                help: supportsWorkspaceBrowser
                    ? (showsWorkspaceCompanion ? L10n.text("apple.workbench.hide") : L10n.text("apple.rootview.show_inspector.aa711c1a"))
                    : isRightSidebarOpen
                    ? L10n.text("apple.rootview.hide_inspector_b.ff55655a")
                    : (inspectorFits
                        ? L10n.text("apple.rootview.show_inspector_b.6cabbee7")
                        : L10n.text("apple.rootview.peek_inspector_b.f0aab686"))
            )
        }
    }

    private func openWorkingTreeBesideChat() {
        guard let id = route.workspaceID else { return }
        desktopTurnReviews[id] = nil
        desktopCommitReviews[id] = nil
        openWorkbench(.changes, in: id)
    }

    private var isLeftSidebarOpen: Bool {
        if windowContentWidth <= 0 { return true }
        if !sidebarColumnFits { return isSidebarPinned }
        return columnVisibilityChoice == .all
    }

    private var isRightSidebarOpen: Bool {
        guard route.hasInspector else { return false }
        if !inspectorFits {
            return isOverlayPinned || isOverlayVisible
        }
        return isInspectorPresented || isOverlayVisible
    }

    private func toggleLeftSidebar() {
        isSidebarOverlayVisible = false

        if windowContentWidth > 0, !sidebarColumnFits {
            isSidebarPinned.toggle()
            if isSidebarPinned {
                isSidebarOverlayVisible = true
            }
            columnVisibilityChoice = .detailOnly
            return
        }
        if columnVisibilityChoice == .all {
            columnVisibilityChoice = .detailOnly
            isSidebarPinned = false
        } else {
            columnVisibilityChoice = .all
            isSidebarPinned = false
        }
    }

    private func revealChanges(in folderID: String, path: String?) {
        if route == .workspace(id: folderID, section: .chat) {
            desktopTurnReviews[folderID] = nil
            desktopCommitReviews[folderID] = nil
            workspaces.focusWorkingTree(in: folderID, path: path)
            openWorkbench(.changes, in: folderID)
            Task { await workspaces.refresh() }
            return
        }
        openSection(.changes, in: folderID) {
            if let path { workspaces.reviewWorkingTree(in: folderID, focusing: path) }
        }
        Task { await workspaces.refresh() }
    }

    private func toggleRightSidebar() {
        guard route.hasInspector else { return }
        if supportsWorkspaceBrowser {
            if showsWorkspaceCompanion { hideWorkbench() }
            else { openWorkbench(workbenchState.selected ?? .inspector) }
            return
        }
        if isInspectorPresented {
            closeInspector()
            return
        }
        isInspectorPresented = true
        if !inspectorFits {
            isOverlayVisible = true
            overlayHeldByPress = true
        }
    }

    static let edgeDwell: TimeInterval = 0.4
    static let edgeGrace: TimeInterval = 0.28
    static let edgeStrip: CGFloat = 32

    static var detailMinimumWidth: CGFloat { DisplayFit.box(480) }

    static var minimumContentWidth: CGFloat {
        detailMinimumWidth + ShellMetrics.railWidth + ShellMetrics.panelInset * 2
    }

    static var minimumContentHeight: CGFloat { DisplayFit.box(620) }

    private static var widthForSidebar: CGFloat { DisplayFit.box(1000) }

    private func inspectorFits(at width: CGFloat) -> Bool {
        let rail = ShellMetrics.railWidth + (ShellMetrics.usesGlass ? ShellMetrics.panelInset * 2 : 6)
        let sidebar = showsSidebarColumn(at: width) ? CGFloat(sidebarWidth) : 0
        return width >= rail + sidebar + DisplayFit.box(Self.comfortDetail) + CGFloat(inspectorWidth)
    }

    private static let comfortDetail: CGFloat = 720

    private var inspectorDragRange: ClosedRange<Double> {
        let range = ShellMetrics.inspectorRange
        guard windowContentWidth > 0 else { return range }
        let rail = ShellMetrics.railWidth + (ShellMetrics.usesGlass ? ShellMetrics.panelInset * 2 : 6)
        let sidebar = showsSidebarColumn(at: windowContentWidth) ? CGFloat(sidebarWidth) : 0
        let room = Double(windowContentWidth - rail - sidebar - DisplayFit.box(Self.comfortDetail))
        return range.lowerBound...max(range.lowerBound, min(range.upperBound, room))
    }

    private var sidebarDragRange: ClosedRange<Double> {
        let range = ShellMetrics.sidebarRange
        guard windowContentWidth > 0, showsInspector, !supportsWorkspaceBrowser else { return range }
        let rail = ShellMetrics.railWidth + (ShellMetrics.usesGlass ? ShellMetrics.panelInset * 2 : 6)
        let room = Double(windowContentWidth - rail - DisplayFit.box(Self.comfortDetail) - CGFloat(inspectorWidth))
        return range.lowerBound...max(range.lowerBound, min(range.upperBound, max(room, sidebarWidth)))
    }

    private func showsSidebarColumn(at width: CGFloat) -> Bool {
        columnVisibilityChoice != .detailOnly
            && (width <= 0 || sidebarColumnFits(
                width: width, browserOpen: showsWorkspaceCompanion, persistedBrowser: browserPaneWidth
            ))
    }

    private func sidebarColumnFits(width: Double, browserOpen: Bool, persistedBrowser: Double) -> Bool {
        if browserOpen {
            let rail = ShellMetrics.railWidth + (ShellMetrics.usesGlass ? ShellMetrics.panelInset * 2 : 6)
            return DesktopWorkbenchLayout.sidebarFits(width: width, rail: rail, sidebar: sidebarWidth, preferredTool: persistedBrowser)
        }
        return width >= Self.widthForSidebar
    }

    private var sidebarColumnFits: Bool {
        windowContentWidth > 0
            && sidebarColumnFits(
                width: windowContentWidth,
                browserOpen: showsWorkspaceCompanion,
                persistedBrowser: browserPaneWidth
            )
    }

    private func applyWidth(for width: CGFloat) {
        if sidebarColumnFits(width: width, browserOpen: showsWorkspaceCompanion, persistedBrowser: browserPaneWidth) {
            if isSidebarPinned {
                columnVisibilityChoice = .all
            }
            isSidebarPinned = false
            isSidebarOverlayVisible = false
        }
        let next = inspectorFits(at: width)
        guard next != inspectorFits else { return }
        Task { @MainActor in
            if inspectorFits != next {
                inspectorFits = next
                if next {
                    isOverlayVisible = false
                    overlayHeldByPress = false
                }
            }
        }
    }

    private var showsSidebar: Bool {
        columnVisibilityChoice != .detailOnly &&
            (windowContentWidth <= 0 || sidebarColumnFits)
    }

    private var showsInspector: Bool {
        isInspectorPresented && route.hasInspector && inspectorFits
    }

    /// The inspector's content, held to the height it has been given.
    ///
    /// `GeometryReader` proposes its own size to what it contains rather than
    /// asking, so a child with an enormous ideal height is handed the pane's
    /// real height and cannot grow the column with a demand of its own. The
    /// clip then keeps the drawing inside that frame as well.
    ///
    /// This is the part `clipped` alone did not do. Clipping restricts
    /// rendering; the size request travels regardless, which is why the window
    /// still came apart with the clip in place.
    @ViewBuilder
    private func boundedInspector<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            content()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        Group {
            switch route {
            case .workspace(_, .todo):
                todoInspector
            case .workspace(_, .notes):
                notesInspector
            case .workspace(_, .chat):
                #if os(macOS)
                WorkspaceInspector(model: workspaces, automations: automations,
                    account: account.account, onClose: { closeInspector() },
                    chat: chat, workspace: workspaces.folders.first { $0.id == route.workspaceID },
                    showsChatOverview: showingChatOverview,
                    onOpenAutomation: { jobID, runID in openAutomation(jobID: jobID, runID: runID) },
                    onOpenPull: { pull in
                        if let folder = workspaces.folders.first(where: { $0.id == route.workspaceID }) {
                            openPull(pull, from: folder)
                        } else if let url = pull.webURL {
                            openURL(url)
                        }
                    })
                #else
                ChatInspector(
                    model: chat,
                    folder: workspaces.folders.first { $0.id == route.workspaceID },
                    onClose: { closeInspector() }
                )
                #endif
            case .workspace(_, .workflows), .global(.workflows):
                WorkflowsInspector(
                    model: workflows,
                    folders: workspaces.folders
                ) { closeInspector() }
            case .workspace(_, .automations), .global(.automations):
                AutomationsInspector(
                    model: automations,
                    folders: workspaces.folders,
                    onReviewWorkspace: { workspaceID, surface in
                        openTaskWorkspaceReview(workspaceID: workspaceID, surface: surface)
                    }
                ) { closeInspector() }
            case .workspace:
                #if os(macOS)
                WorkspaceInspector(
                    model: workspaces,
                    automations: automations,
                    account: account.account,
                    onClose: { closeInspector() },
                    onOpenAutomation: { jobID, runID in
                        openAutomation(jobID: jobID, runID: runID)
                    }
                )
                #else
                WorkspaceInspector(
                    model: workspaces,
                    account: account.account
                ) { closeInspector() }
                #endif
            case .global(.home):
                HomeInspector(
                    model: home,
                    onOpenInsights: { day in
                        model.focusOn(day: day)
                        navigate(to: .global(.insights))
                    }
                ) { closeInspector() }
            case .global(.todo):
                todoInspector
            case .global(.notes):
                notesInspector
            case .global(.machines):
                MachinesInspector(model: machines) { closeInspector() }
            case let .sshTerminals(hostID):
                #if os(macOS)
                SSHSessionInspector(
                    model: ssh,
                    sessions: sshSessions,
                    hostID: hostID
                ) { closeInspector() }
                #else
                EmptyView()
                #endif
            case let .ssh(section):
                #if os(macOS)
                SSHInspector(model: ssh, section: section) { closeInspector() }
                #else
                EmptyView()
                #endif
            case .global(.insights):
                ScopedInsightsInspector(model: model) { closeInspector() }
            case .global(.account), .global(.newChat), .global(.team):
                EmptyView()
            case .workspacesOverview:
                RepositoryPeek(model: repositoryOverview,
                               folders: workspaces.folders.filter { !$0.isGeneral },
                               actions: repositoryActions,
                               onClose: { closeInspector() })
            }
        }
    }

    private var todoInspector: some View {
        TodoInspector(
            model: todo,
            folders: workspaces.folders,
            onViewRun: { runID, workspaceID in
                openTaskRun(runID: runID, workspaceID: workspaceID)
            },
            onRunInFront: { launch in
                launchTaskInFront(launch)
            },
            onOpenTerminal: { info in openTaskTerminal(info) },
            onReviewWorkspace: { workspaceID, surface in
                openTaskWorkspaceReview(workspaceID: workspaceID, surface: surface)
            }
        ) { closeInspector() }
    }

    private var notesInspector: some View {
        NotesInspector(model: todo, folders: workspaces.folders) { closeInspector() }
    }

    private var usesOverlayInspector: Bool {
        route.hasInspector && !supportsWorkspaceBrowser && (!isInspectorPresented || !inspectorFits)
    }

    private var isOverlayPinned: Bool { overlayHeldByPress }

    private var usesOverlaySidebar: Bool {
        guard windowContentWidth > 0 else { return false }
        return !showsSidebar
    }

    private var showsSidebarOverlay: Bool {
        usesOverlaySidebar && (isSidebarPinned || isSidebarOverlayVisible)
    }

    private var isSidebarModalVisible: Bool {
        sessionPendingClose != nil
            || workspacePendingRemove != nil
            || workspacePendingChatRemoval != nil
            || stoppingSharing != nil
            || sshHostPendingClose != nil
    }

    private var showsOverlayInspector: Bool {
        usesOverlayInspector && (isOverlayPinned || isOverlayVisible)
    }

    private var detailColumn: some View {
        LiveDetailColumn(drag: columnDrag, minimumDetail: Self.detailMinimumWidth,
                         storedInspector: showsInspector && !supportsWorkspaceBrowser ? inspectorWidth : nil) {
            detail
                .frame(minWidth: Self.detailMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                .background { DesktopContentSheet(topInset: chromeHeaderInset) }
            if hasDockedWorkbench {
                DesktopWorkbenchSpace(resize: workbenchResize, preferred: browserPaneWidth, cap: { maximumWorkbenchWidth })
            } else if showsInspector && !supportsWorkspaceBrowser {
                boundedInspector { inspectorContent }
                    .background { Theme.background.padding(.top, chromeHeaderInset) }
                    .overlay(alignment: .leading) {
                        ColumnResizeHandle(
                            side: .trailing,
                            width: $inspectorWidth,
                            liveWidth: { columnDrag.inspector }, setLiveWidth: { columnDrag.inspector = $0 },
                            range: inspectorDragRange,
                            help: L10n.text("apple.rootview.drag_to_resize_the_inspector_double_click.9aa43689")
                        )
                        .padding(.top, chromeHeaderInset)
                        .offset(x: -3)
                    }
            }
        }
            .overlay(alignment: .leading) { sidebarFloatLayer.padding(.top, chromeHeaderInset) }
            .overlay(alignment: .trailing) {
                inspectorFloatLayer
                    .environment(\.desktopChromeJoined, false)
                    .padding(.top, chromeHeaderInset)
            }
            .overlay(alignment: .trailing) {
                if let id = chatFolder, !desktopWorkbench.state(in: id).tabs.isEmpty {
                    DesktopWorkbenchPanel(resize: workbenchResize, preferred: $browserPaneWidth,
                                          cap: { maximumWorkbenchWidth }, isVisible: showsWorkspaceCompanion,
                                          dividerTopInset: hasDockedWorkbench ? chromeHeaderInset : 0) {
                        workspaceCompanionPane
                            .background {
                                Theme.sidebar.padding(.top, hasDockedWorkbench ? chromeHeaderInset : 0)
                            }
                            .environment(\.desktopChromeJoined, hasDockedWorkbench && usesUnifiedChrome)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.top, hasDockedWorkbench ? 0 : chromeHeaderInset)
                    .shadow(color: Theme.shadow(showsWorkspaceCompanion && !browserFitsBesideWorkspace ? 0.2 : 0), radius: 12, x: -5)
                    .opacity(showsWorkspaceCompanion ? 1 : 0)
                    .allowsHitTesting(showsWorkspaceCompanion)
                    .accessibilityHidden(!showsWorkspaceCompanion)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: showsOverlayInspector
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: showsSidebarOverlay
            )
    }

    private var supportsWorkspaceBrowser: Bool {
        route.workspaceSection == .chat
    }

    private var showsWorkspaceBrowser: Bool {
        showsWorkspaceCompanion && workbenchState.selected == .browser
    }

    private var showsWorkspaceTerminal: Bool {
        showsWorkspaceCompanion && workbenchState.selected == .terminal
    }

    private var workbenchState: DesktopWorkbenchState {
        (route.workspaceID ?? chatFolder).map { desktopWorkbench.state(in: $0) } ?? DesktopWorkbenchState()
    }

    private var showsWorkspaceCompanion: Bool { supportsWorkspaceBrowser && workbenchState.isPresented }

    private func openWorkbench(_ tool: DesktopWorkbenchState.Tool, in workspaceID: String? = nil) {
        guard let id = workspaceID ?? route.workspaceID else { return }
        desktopWorkbench.open(tool, in: id)
    }

    private func hideWorkbench() {
        desktopWorkbench.hide()
    }

    private func closeWorkbench(_ tool: DesktopWorkbenchState.Tool, in workspaceID: String) {
        desktopWorkbench.close(tool, in: workspaceID)
        if tool == .changes {
            desktopTurnReviews[workspaceID] = nil
            desktopCommitReviews[workspaceID] = nil
        }
        if tool == .browser { workspaceBrowserURLs[workspaceID] = nil }
        if tool == .simulator { simulatorRequests[workspaceID] = nil }
        if tool == .terminal { desktopTerminalRequests[workspaceID] = nil }
    }

    @ViewBuilder private var workspaceCompanionPane: some View {
        if let id = chatFolder,
           let folder = workspaces.folders.first(where: { $0.id == id }) {
            let state = desktopWorkbench.state(in: id)
            VStack(spacing: 0) {
                DesktopWorkbenchBar(state: state,
                    open: { openWorkbench($0, in: id) },
                    close: { closeWorkbench($0, in: id) },
                    hide: { hideWorkbench() })
                ZStack {
                    ForEach(state.tabs) { tool in
                        let active = showsWorkspaceCompanion && state.selected == tool
                        workbenchContent(tool, folder: folder, active: active)
                            .environment(\.desktopChromeJoined, false)
                            .id(tool == .inspector ? nil : id)
                            .retainedPane(isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private func workbenchContent(_ tool: DesktopWorkbenchState.Tool, folder: WorkspaceFolder, active: Bool) -> some View {
        switch tool {
        case .changes:
            ChatChangesWorkbenchView(folder: folder, model: workspaces, automations: automations,
                review: desktopTurnReviews[folder.id], commitID: desktopCommitReviews[folder.id], isActive: active,
                showWorkingTree: {
                    desktopTurnReviews[folder.id] = nil
                    desktopCommitReviews[folder.id] = nil
                })
        case .browser:
            ProjectBrowserView(workspaceID: folder.id, initialURL: workspaceBrowserURLs[folder.id] ?? "", allowsExternalNavigation: true, isSurfaceVisible: active) {
                workspaceBrowserURLs[folder.id] = $0
            }
        case .simulator:
            SimulatorInspector(workspaceID: folder.id, isActive: active,
                request: Binding(get: { simulatorRequests[folder.id] }, set: { simulatorRequests[folder.id] = $0 }))
        case .terminal:
            ChatTerminalPane(folder: folder, terminals: terminals, workspaces: workspaces,
                             ssh: ssh, sshSessions: sshSessions,
                             onManageServers: { openSSH(.hosts(folder: nil)) },
                             onClose: { hideWorkbench() }, isActive: active,
                             request: Binding(get: { desktopTerminalRequests[folder.id] }, set: { desktopTerminalRequests[folder.id] = $0 }))
        case .inspector:
            WorkspaceInspector(model: workspaces, automations: automations,
                account: account.account, onClose: { hideWorkbench() },
                chat: chat, workspace: folder, showsChatOverview: showingChatOverview,
                onOpenAutomation: { id, runID in openAutomation(jobID: id, runID: runID) },
                onReviewWorkingTree: { path in
                    workspaces.focusWorkingTree(in: folder.id, path: path)
                    desktopTurnReviews[folder.id] = nil
                    desktopCommitReviews[folder.id] = nil
                    openWorkbench(.changes, in: folder.id)
                }, onReviewCommit: { commitID in
                    desktopTurnReviews[folder.id] = nil
                    desktopCommitReviews[folder.id] = commitID
                    openWorkbench(.changes, in: folder.id)
                })
        }
    }

    private var browserFitsBesideWorkspace: Bool {
        DesktopWorkbenchLayout.fitsBeside(available: windowContentWidth - leftChromeWidth)
    }

    private var maximumWorkbenchWidth: CGFloat {
        let available = windowContentWidth - leftChromeWidth
        return browserFitsBesideWorkspace
            ? ChromeFit.besideMax(available: available)
            : ChromeFit.overlayMax(width: available)
    }

    @ViewBuilder
    private var sidebarFloatLayer: some View {
        if showsSidebarOverlay {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: currentSidebarWidth)
                    .frame(maxHeight: .infinity)
                    .modifier(FloatingSidebarSurface(isFullScreen: isFullScreen))
                    .shadow(color: Theme.shadow(0.20), radius: 12, x: 5, y: 0)

                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissSidebarOverlay() }
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var inspectorFloatLayer: some View {
        if showsOverlayInspector && !supportsWorkspaceBrowser {
            HStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissOverlay() }

                boundedInspector { inspectorContent }
                    .frame(width: currentInspectorWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.sidebar)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.border)
                            .frame(width: 1)
                    }
                    .shadow(color: Theme.shadow(0.20), radius: 12, x: -5, y: 0)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var needsEdgeWatcher: Bool {
        scenePhase == .active && (usesOverlayInspector || isTransientSidebarVisible)
    }

    private var isTransientSidebarVisible: Bool {
        usesOverlaySidebar && isSidebarOverlayVisible && !isSidebarPinned && !isSidebarModalVisible
    }

    /// Open and close both edge peeks from where the pointer actually is.
    ///
    /// **`onHover` was the wrong source.** It reports crossings, and it misses
    /// them: a pointer that leaves fast, leaves onto another window, or leaves
    /// while a menu takes the mouse never produces the exit event, so a pane
    /// that opened stayed open with nothing under the pointer. Reported as
    /// "it does not always auto close", and it is not a timing bug that a
    /// longer grace period fixes, it is an event that never arrives.
    ///
    /// Asking `NSEvent.mouseLocation` cannot miss anything. Ten times a second
    /// is far below anything measurable and it answers both questions at once:
    /// has the pointer rested at the edge long enough to mean it, and has it
    /// actually left.
    ///
    /// **A peek that is not docked always auto-hides**, at every window size.
    /// Pinning belongs to the toolbar toggle alone: it is the docked state, and
    /// on a window too narrow to carry the column a pinned float is what
    /// "docked" has to mean. Nothing else pins, so nothing can lock a pane
    /// open behind the user's back.
    @MainActor
    private func watchPointer() async {
        #if os(macOS)
        var trailingSince: Date?
        var trailingLeftAt: Date?
        var leadingLeftAt: Date?
        let now = { Date() }

        while !Task.isCancelled {
            if usesOverlayInspector {
                let width = showsOverlayInspector ? currentInspectorWidth : Self.edgeStrip
                let inside = Self.pointerIsNear(.trailing, within: width)
                if inside {
                    trailingLeftAt = nil
                    if overlayHeldByPress { overlayHeldByPress = false }
                    if showsOverlayInspector {
                        trailingSince = nil
                    } else {
                        let since = trailingSince ?? now()
                        trailingSince = since
                        if now().timeIntervalSince(since) >= Self.edgeDwell {
                            isOverlayVisible = true
                            trailingSince = nil
                        }
                    }
                } else {
                    trailingSince = nil
                    if isOverlayVisible, !isOverlayPinned {
                        let left = trailingLeftAt ?? now()
                        trailingLeftAt = left
                        if now().timeIntervalSince(left) >= Self.edgeGrace {
                            isOverlayVisible = false
                            trailingLeftAt = nil
                        }
                    } else {
                        trailingLeftAt = nil
                    }
                }
            } else {
                trailingSince = nil
                trailingLeftAt = nil
            }

            if isTransientSidebarVisible {
                let width = leftChromeWidth + currentSidebarWidth
                if Self.pointerIsNear(.leading, within: width) {
                    leadingLeftAt = nil
                } else {
                    let left = leadingLeftAt ?? now()
                    leadingLeftAt = left
                    if now().timeIntervalSince(left) >= Self.edgeGrace {
                        isSidebarOverlayVisible = false
                        leadingLeftAt = nil
                    }
                }
            } else {
                leadingLeftAt = nil
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
        #endif
    }

    #if os(macOS)
    private static func pointerIsNear(_ edge: HorizontalEdge, within width: CGFloat) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible else {
            return false
        }
        let point = NSEvent.mouseLocation
        let frame = window.frame
        guard frame.contains(point) else { return false }
        switch edge {
        case .trailing: return point.x >= frame.maxX - width
        case .leading: return point.x <= frame.minX + width
        }
    }
    #endif

    private func dismissOverlay() {
        isInspectorPresented = false
        isOverlayVisible = false
        overlayHeldByPress = false
    }

    private func dismissSidebarOverlay() {
        guard !isSidebarModalVisible else { return }
        isSidebarPinned = false
        isSidebarOverlayVisible = false
    }

    private func closeInspector() {
        isInspectorPresented = false
        isOverlayVisible = false
        overlayHeldByPress = false
    }


    #if os(macOS)
    private var sshLiveHosts: [SSHHost] {
        let ids = Set(sshSessions.sessions.compactMap(\.hostID))
        return ssh.hosts
            .filter { ids.contains($0.id) || $0.favorite }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    @ViewBuilder
    private func sshFavoriteHostRow(_ host: SSHHost) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 18, height: 24)
            SidebarRow(label: host.label, symbol: "star.fill", symbolSize: 11, trailing: nil, isSelected: false,
                       folderMetrics: true) {
                ssh.connectRequest = host
            }
            .help(L10n.text("common.connect"))
        }
        .contextMenu {
            Button(L10n.text("common.connect"), .connect) { ssh.connectRequest = host }
            Button(L10n.text("common.open"), .next) { navigate(to: .sshTerminals(host: host.id)) }
        }
    }

    @ViewBuilder
    private func sshLiveHostRow(_ host: SSHHost) -> some View {
        let mine = sshSessions.sessions(for: host.id)
        let isExpanded = expandedSSHHosts.contains(host.id)
        let isCurrent = route.sshTerminalHostID == host.id
        HStack(spacing: 0) {
            Button {
                if isExpanded {
                    setServerExpanded(host.id, false)
                } else {
                    setServerExpanded(host.id, true)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.font(8, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Color.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
            .help(isExpanded ? L10n.text("apple.rootview.collapse_sessions.1976b67d") : L10n.text("apple.rootview.expand_sessions.3675e61a"))

            SidebarRow(
                label: host.label,
                symbol: "terminal",
                trailing: "\(sshSessions.liveCount(for: host.id))",
                isSelected: isCurrent && !isExpanded,
                folderMetrics: true
            ) { navigate(to: .sshTerminals(host: host.id)) }
        }
        .contextMenu {
            Button(L10n.text("apple.rootview.new_terminal.fe544556"), .create) { ssh.connectRequest = host }
            Button(L10n.text("apple.rootview.close_all_sessions.d07695b4"), .delete, role: .destructive) {
                sshHostPendingClose = host
            }
            ThemeRule()
            Button(isExpanded ? L10n.text("common.collapse") : L10n.text("common.expand"), .collapse) {
                if isExpanded {
                    setServerExpanded(host.id, false)
                } else {
                    setServerExpanded(host.id, true)
                }
            }
        }
        if isExpanded {
            ForEach(mine) { session in
                SidebarRow(
                    label: session.title,
                    symbol: session.alive ? "terminal" : "terminal.fill",
                    trailing: session.alive ? nil : "ended",
                    isSelected: isCurrent && sshSessions.selectedID == session.id
                ) {
                    sshSessions.select(session)
                    navigate(to: .sshTerminals(host: host.id))
                }
                .padding(.leading, 18)
                .contextMenu {
                    Button(L10n.text("common.close"), .delete, role: .destructive) {
                        Task { await sshSessions.close(session) }
                    }
                }
            }
        }
    }

    #endif

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sidebarSectionOrder, id: \.self) { section in
                            if section == "projects" { projectsSection }
                            else if section == "servers" { liveServersSection }
                        }
                    }
                    .padding(.bottom, Theme.Space.m)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: chat.selected?.id) { _, id in
                    guard let id, route.workspaceSection == .chat else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.sidebarChatRowID(id))
                    }
                }
            }
            accountFooter
        }
        .background {
            RemoveWorkspaceConfirm(
                folder: $workspacePendingRemove,
                remove: { folder in
                    Task { await workspaces.remove(folder) }
                }
            )
        }
        .background {
            RemoveAllChatsConfirm(
                folder: $workspacePendingChatRemoval,
                remove: { folder in
                    Task { await chat.removeAll(in: folder.id) }
                }
            )
        }
        .background {
            Color.clear.frame(width: 0, height: 0)
                .modifier(TeamAgentApprovalPrompt(store: teams) { publication in
                    workspaces.folders.first { $0.id == publication.workspaceId }?.name
                })
                .modifier(TeamStopSharingConfirm(store: teams, request: $stoppingSharing) {
                    Task { await workspaces.loadLocal() }
                })
        }
        .background {
            CloseSessionConfirm(
                session: $sessionPendingClose,
                close: { session in
                    Task { await terminals.close(session) }
                }
            )
        }
        .background {
            CloseSSHSessionsConfirm(
                host: $sshHostPendingClose,
                sessionCount: { sshSessions.sessions(for: $0.id).count },
                close: { host in
                    Task { await sshSessions.closeAll(for: host.id) }
                }
            )
        }
    }


    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Wordmark(size: 15)
            }
            .padding(.leading, showsSidebar && !isFullScreen ? 26 : Theme.Space.m)
            .padding(.trailing, Theme.Space.m)
            .chromeBarMetrics()
            .background {
                if showsSidebar && !isFullScreen {
                    TitlebarDragArea().accessibilityHidden(true)
                }
            }
            SidebarRow(
                label: L10n.text("apple.rootview.new_chat.db18382a"),
                symbol: "square.and.pencil", trailing: nil,
                isSelected: route.isGlobal(.newChat)
            ) { startNewChat() }
            SidebarRow(
                label: L10n.text("common.search"),
                symbol: "magnifyingglass",
                trailing: "⌘K",
                isSelected: false
            ) { showWorkSearch = true }
        }
        .padding(.bottom, Theme.Space.xs)
    }

    private func startNewChat(in chosen: WorkspaceFolder? = nil) {
        if let chosen, !chosen.isRemote, !teams.localProjects(for: chosen.id).isEmpty {
            openSharedProject(chosen)
            return
        }
        startPrivateChat(in: chosen)
    }

    private func startPrivateChat(in chosen: WorkspaceFolder? = nil) {
        chat.saveDraftNow()
        chatStart.activate(scope: WorkSessionContext.shared.scope, session: WorkSessionContext.shared.generation,
                           repositoryID: chosen?.id)
        navigate(to: .global(.newChat))
    }

    private var newChatPage: some View {
        ChatStartPage(draft: chatStart, repositories: workspaces.folders,
                      isFullScreen: isFullScreen,
                      repositoriesLoading: workspaces.isLoading || workspaces.directoryPresentation == .loading,
                      onAdd: {
                          if let owner = chatStart.owner {
                              chatStartAdd = (owner, Set(workspaces.folders.map(\.id)))
                          }
                          workspaces.requestAdd()
                      }, onSend: { Task { await sendNewChat() } },
                      onAddFolders: { urls in
                          guard let owner = chatStart.owner else { return }
                          let selection = chatStart.repositoryID
                          let reference = chatStart.attachmentReference
                          Task {
                              let added = await workspaces.add(urls)
                              guard route.isGlobal(.newChat), chatStart.owner == owner,
                                    chatStart.attachmentReference == reference,
                                    chatStart.repositoryID == selection, !chatStart.isSubmitting,
                                    let added, workspaces.folders.contains(where: { $0.id == added }) else { return }
                              chatStart.repositoryID = added
                          }
                      },
                      glance: home.glance)
            .onAppear {
                chatStart.activate(scope: WorkSessionContext.shared.scope, session: WorkSessionContext.shared.generation)
            }
            .onChange(of: WorkSessionContext.shared.generation) { _, generation in
                chatStart.activate(scope: WorkSessionContext.shared.scope, session: generation)
            }
            .onDisappear { chatStart.retire(); chatStartAdd = nil }
    }

    private func finishChatStartAdd() {
        defer { chatStartAdd = nil }
        guard let request = chatStartAdd, route.isGlobal(.newChat), chatStart.owner == request.owner,
              let selected = workspaces.selectedID, !request.repositories.contains(selected),
              workspaces.folders.contains(where: { $0.id == selected }) else { return }
        chatStart.repositoryID = selected
    }

    private func sendNewChat() async {
        guard let submission = chatStart.begin(available: Set(workspaces.folders.map(\.id))) else { return }
        let deadline = ContinuousClock.now.advanced(by: ChatStartPreparation.budget)
        defer { chatStart.failed(submission, message: nil); chatStart.finishPresentation(submission) }
        func current() -> Bool {
            !Task.isCancelled && route.isGlobal(.newChat)
                && chatStart.accepts(submission, scope: WorkSessionContext.shared.scope, session: WorkSessionContext.shared.generation)
                && workspaces.folders.contains(where: { $0.id == submission.repositoryID })
        }
        let reader = ChatModel()
        reader.newChatChoice = submission.agent
        await reader.load(workspaceID: submission.repositoryID, selectFirst: false)
        guard current() else { return }
        guard reader.error == nil, reader.isReady(for: submission.repositoryID),
              let created = await reader.create() else {
            chatStart.failed(submission, message: reader.error ?? L10n.text("apple.chatview.chat_unavailable.a45aae80"))
            return
        }
        func abandon(_ message: String?) async {
            let preserved = message ?? reader.error
            if submission.owner.scope == WorkSessionContext.shared.scope {
                await reader.remove(created)
            }
            chatStart.failed(submission, message: preserved)
        }
        guard current(), reader.selected?.id == created.id,
              await reader.installLandingDraft(submission, permits: current) else {
            await abandon(reader.error)
            return
        }
        if submission.agent.fastMode {
            await reader.update(fastMode: true)
            guard current(), reader.selected?.id == created.id, reader.selected?.fastMode == true, reader.error == nil else {
                await abandon(reader.error ?? L10n.text("common.new_chat.setup_changed"))
                return
            }
        }
        guard current(), reader.selected?.id == created.id else {
            await abandon(nil)
            return
        }
        chatStart.transferred(submission, preparingPresentation: true)
        await ChatStartPreparation.preload(until: deadline) { await reader.sendInitialDraft() }
        guard !Task.isCancelled, route.isGlobal(.newChat),
              workspaces.folders.contains(where: { $0.id == submission.repositoryID }),
              chatStart.ownsPresentation(submission, scope: WorkSessionContext.shared.scope,
                                        session: WorkSessionContext.shared.generation) else { return }
        reader.prepareInitialPresentation()
        chat.saveDraftNow()
        chat = reader
        openSection(.chat, in: submission.repositoryID)
    }

    @ViewBuilder
    private var projectsSection: some View {
        SidebarGroupHeader(
            title: projectsDisplay == .byChat ? L10n.text("common.chats") : L10n.text("common.projects"),
            count: projectsDisplay == .byChat ? nil : projectsSectionCount,
            isExpanded: expandedSidebarSections.contains("projects")
        ) { toggleSidebarSection("projects") } trailing: {
            #if os(macOS)
            if !workspaces.folders.isEmpty {
                SidebarViewSwitch(display: projectsDisplay) { setProjectsDisplay($0) }
                SidebarHeaderIconButton(
                    systemImage: ActionIcon.filter.symbol,
                    help: L10n.text("common.sidebar.filter_repositories"),
                    isOn: showingProjectsFilter || !projectsFilter.isEmpty
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if showingProjectsFilter {
                            closeProjectsFilter()
                        } else {
                            showingProjectsFilter = true
                            if !expandedSidebarSections.contains("projects") {
                                toggleSidebarSection("projects")
                            }
                        }
                    }
                }
            }
            #endif
            projectsSectionMenu()
            #if os(macOS)
            if projectsDisplay == .byChat && !workspaces.folders.isEmpty {
                projectsAddMenu()
            } else {
                SidebarHeaderIconButton(
                    systemImage: "folder.badge.plus",
                    help: L10n.text("apple.rootview.add_a_project_folder.1fb6a975")
                ) {
                    workspaces.requestAdd()
                }
            }
            #endif
        }

        if expandedSidebarSections.contains("projects") {
            #if os(macOS)
            if !workspaces.folders.isEmpty && (showingProjectsFilter || !projectsFilter.isEmpty) {
                SidebarFilterField(
                    text: $projectsFilter,
                    prompt: projectsDisplay == .byChat
                        ? L10n.text("common.sidebar.filter_chats")
                        : L10n.text("common.sidebar.filter_repositories")
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { closeProjectsFilter() }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #endif
            if workspaces.folders.isEmpty {
                if workspaces.directoryPresentation == .empty {
                    FirstProjectPrompt(compact: true) { workspaces.requestAdd() }
                } else {
                    WorkspaceDirectoryPlaceholder(presentation: workspaces.directoryPresentation,
                        error: workspaces.directoryError, compact: true) {
                        Task { await workspaces.loadLocal() }
                    }
                }
            } else if projectsDisplay == .byChat {
                projectsChatCentricList
                    .task(id: workspaces.folders.map(\.id) + [String(describing: ObjectIdentifier(chat)), projectsDisplay.rawValue]) {
                        await warmAllProjectChatLists()
                    }
                    .onChange(of: projectsFilter) { _, _ in
                        chatListLimit = SidebarProjectsLayout.chatPageSize
                    }
            } else {
                ForEach(visibleProjectFolders) { folder in
                    projectRow(folder)
                }
                .task(id: workspaces.folders.map(\.id) + [projectsSort.rawValue, showingProjectsFilter ? "filter" : "", String(describing: ObjectIdentifier(chat))]) {
                    #if os(macOS)
                    if projectsSort == .recent {
                        await warmAllProjectChatLists()
                    } else if showingProjectsFilter {
                        await warmAllProjectChatLists(onlyUnread: true)
                    } else {
                        chat.retainSidebarWorkspaceLists([])
                    }
                    #endif
                }
                #if os(macOS)
                if workspaceDropBeforeID == WorkspaceDrag.end {
                    workspaceInsertionLine
                }
                #endif
            }
            #if os(macOS)
            Button {
                workspaces.requestAdd()
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "plus.circle")
                        .font(Theme.font(11, weight: .semibold))
                    Text(L10n.text("apple.rootview.add_project.43079d4a"))
                        .font(Theme.callout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 8))
            .padding(.top, workspaces.folders.isEmpty ? 0 : Theme.Space.xs)
            .modifier(WorkspaceReorder(id: WorkspaceDrag.end, canDrag: false,
                                       enabled: projectsDisplay == .byRepository
                                        && projectsSort == .manual
                                        && workspaces.folders.count > 1) {
                workspaces.moveWorkspace($0, before: nil)
                workspaceDropBeforeID = nil
            } onTargeted: { on in
                if on {
                    workspaceDropBeforeID = WorkspaceDrag.end
                } else if workspaceDropBeforeID == WorkspaceDrag.end {
                    workspaceDropBeforeID = nil
                }
            })
            #endif
        }
    }

    private var visibleProjectFolders: [WorkspaceFolder] {
        let filtered = workspaces.folders.filter { folder in
            let chats = chat.sidebarChats(in: folder.id).filter { !chat.isUntouched($0, in: folder.id) }
            return SidebarProjectsLayout.matches(projectsFilter, folder: folder, chats: chats)
        }
        return SidebarProjectsLayout.orderedFolders(filtered, sort: projectsSort) { folder in
            chat.sidebarChats(in: folder.id)
                .map { $0.lastMessageAtMs ?? $0.updatedAtMs }
                .max() ?? 0
        }
    }

    private var projectsSectionCount: Int {
        if projectsDisplay == .byChat {
            return visibleChatEntries.count
        }
        return visibleProjectFolders.count
    }

    private var visibleChatEntries: [SidebarChatEntry] {
        SidebarProjectsLayout.chatEntries(
            folders: workspaces.folders,
            chats: { folder in
                chat.sidebarChats(in: folder.id).filter { !chat.isUntouched($0, in: folder.id) }
            },
            query: projectsFilter,
            sort: .recent
        )
    }

    @ViewBuilder
    private var projectsChatCentricList: some View {
        let entries = visibleChatEntries
        if entries.isEmpty {
            Text(projectsFilter.isEmpty
                 ? L10n.text("apple.rootview.no_chats_yet.269208e4")
                 : L10n.text("common.sidebar.no_matching_chats"))
                .font(Theme.fit(12))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 6)
        } else {
            let shown = Array(entries.prefix(chatListLimit))
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(SidebarProjectsLayout.dayGroups(shown)) { group in
                    let collapsed = collapsedChatDays.contains(group.id)
                    SidebarChatDayHeader(
                        title: chatDayTitle(group.day),
                        isWorking: group.day == .working,
                        isCollapsed: collapsed
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if collapsed {
                                collapsedChatDays.remove(group.id)
                            } else {
                                collapsedChatDays.insert(group.id)
                            }
                        }
                    }
                    if !collapsed {
                        ForEach(group.entries) { entry in
                            chatListRow(entry)
                        }
                    }
                }
                if entries.count > shown.count {
                    let more = min(SidebarProjectsLayout.chatPageSize, entries.count - shown.count)
                    SidebarShowMoreRow(title: L10n.text("apple.rootview.show_0_more.b91c3640", "\(more)")) {
                        chatListLimit += SidebarProjectsLayout.chatPageSize
                    }
                    .padding(.top, Theme.Space.xs)
                }
            }
        }
    }

    private func openChatEntry(_ entry: SidebarChatEntry) {
        let folder = entry.folder
        let conversation = entry.conversation
        if chat.folderID == folder.id {
            openSection(.chat, in: folder.id) {
                Task { await chat.select(conversation) }
            }
        } else {
            chat.reveal(id: conversation.id, in: folder.id)
            openSection(.chat, in: folder.id)
        }
    }

    private func stepChatList(_ step: Int) -> Bool {
        guard projectsDisplay == .byChat, step == -1 || step == 1 else { return false }
        let shown = Array(visibleChatEntries.prefix(chatListLimit))
        let rows = SidebarProjectsLayout.dayGroups(shown).flatMap { group in
            collapsedChatDays.contains(group.id) ? [] : group.entries
        }
        guard !rows.isEmpty else { return false }
        let next: Int
        if let current = rows.firstIndex(where: {
            $0.conversation.id == chat.selected?.id && $0.folder.id == chat.folderID
        }) {
            next = (current + step + rows.count) % rows.count
        } else {
            next = step > 0 ? 0 : rows.count - 1
        }
        openChatEntry(rows[next])
        let count = rows.count
        let nearby = [step, 2 * step, 3 * step, -step].map { rows[((next + $0) % count + count) % count] }
            .filter { $0.conversation.id != rows[next].conversation.id }
        Task {
            for entry in nearby {
                await chat.warmConversationPreview(entry.conversation, in: entry.folder.id)
            }
        }
        return true
    }

    private func chatListRow(_ entry: SidebarChatEntry) -> some View {
        let folder = entry.folder
        let conversation = entry.conversation
        return ChatSidebarConversationRow(
            conversation: conversation,
            folder: folder,
            rename: { try await chat.rename(conversation, in: folder.id, to: $0) },
            fork: {
                let previousRoute = route
                let copied = try await chat.fork(conversation, in: folder.id)
                if route == previousRoute {
                    chat.reveal(id: copied.id, in: folder.id)
                    openSection(.chat, in: folder.id)
                }
            },
            draft: chat.draftReference(for: conversation.id, in: folder.id),
            runningSince: chat.turnStartedAt(for: conversation.id),
            isSelected: chat.selected?.id == conversation.id
                && !showingChatOverview
                && route == .workspace(id: folder.id, section: .chat),
            select: { openChatEntry(entry) },
            remove: {
                Task { await chat.remove(conversation, in: folder.id) }
            },
            openPull: { openPull($0, from: folder) },
            warmPreview: { await chat.warmConversationPreview(conversation, in: folder.id) },
            caption: folder.isRemote
                ? "\(folder.machineLabel ?? L10n.text("apple.rootview.remote.ffa98e02")) / \(folder.name)"
                : folder.name,
            folderIsOpen: chat.folderID == folder.id
        )
        .equatable()
        .id(Self.sidebarChatRowID(conversation.id))
    }

    private func chatDayTitle(_ day: SidebarChatDay) -> String {
        switch day {
        case .working: return L10n.text("common.working")
        case .today: return L10n.text("common.today")
        case .yesterday: return L10n.text("common.yesterday")
        case .older: return L10n.text("common.sidebar.older")
        case .day(let date):
            let language = Locale(identifier: Locale.preferredLanguages.first ?? "en")
            return date.formatted(.dateTime.month(.abbreviated).day().locale(language))
        }
    }

    @ViewBuilder
    private func projectRow(_ folder: WorkspaceFolder) -> some View {
        #if os(macOS)
        if workspaceDropBeforeID == folder.id {
            workspaceInsertionLine
        }
        let activeSessions = terminals.sessions(in: folder.id).filter(\.alive)
        let isCurrent = route.workspaceID == folder.id
        let showingLauncher = isCurrent
            && workspaces.isShowingLauncher(in: folder.id)
        let showingTerminal = isCurrent
            && route.workspaceSection == .sessions
            && workspaces.isShowingTerminal(in: folder.id)
            && terminals.activeTerminal(in: folder.id) != nil
        let filterOpen = !projectsFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isExpanded = expandedWorkspaces.contains(folder.id) || filterOpen
        let showingChat = isCurrent
            && route.workspaceSection == .chat
            && !showingChatOverview
            && chat.folderID == folder.id
            && chat.selected != nil
        HStack(spacing: 0) {
            Button {
                if filterOpen { return }
                if isExpanded {
                    setProjectExpanded(folder.id, false)
                } else {
                    setProjectExpanded(folder.id, true)
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.font(8, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Color.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
            .help(isExpanded ? L10n.text("apple.rootview.collapse_project.96385e6d") : L10n.text("apple.rootview.expand_project.1e7feb92"))

            WorkspaceRow(
                folder: folder,
                isSelected: isCurrent
                    && (!isExpanded || showingLauncher || !(showingTerminal || showingChat)),
                isCurrent: isCurrent,
                summary: workspaces.summary(for: folder.id),
                activeTerminals: activeSessions.count,
                isStale: folder.machineID.map { workspaces.isRemoteStale($0) } ?? false,
                isShared: !folder.isRemote && !teams.localProjects(for: folder.id).isEmpty,
                share: folder.isRemote || folder.isGeneral ? nil : { openSharedProject(folder) },
                rename: { name in
                    let scope = WorkSessionContext.shared.scope
                    let reference = pinReference(for: folder)
                    try await Bridge.renameWorkspace(id: folder.id, name: name)
                    guard scope == WorkSessionContext.shared.scope else { return }
                    await workspaces.load()
                    if let reference, pins.isPinned(reference) {
                        pins.pin(reference, label: name, folderName: name)
                    }
                },
                remove: { workspacePendingRemove = folder },
                reveal: { workspaces.revealInFinder(folder) },
                newChat: { startNewChat(in: folder) },
                actions: { projectActions(folder) },
                action: { selectWorkspace(folder.id) }
            )
        }
        .modifier(WorkspaceReorder(
            id: folder.id,
            enabled: projectsSort == .manual && workspaces.folders.count > 1
        ) {
            workspaces.moveWorkspace($0, before: folder.id)
            workspaceDropBeforeID = nil
        } onTargeted: { on in
            if on {
                workspaceDropBeforeID = folder.id
            } else if workspaceDropBeforeID == folder.id {
                workspaceDropBeforeID = nil
            }
        })
        #else
        SidebarRow(
            label: folder.name,
            symbol: folder.exists ? "folder" : "questionmark.folder",
            trailing: folder.diffStat,
            isSelected: route.workspaceID == folder.id
        ) { selectWorkspace(folder.id) }
        .help(folder.path)
        .contextMenu {
            ThemeRule()
            Button(L10n.text("apple.rootview.remove_from_tokenstat.24f9beb7"), .delete, role: .destructive) {
                workspacePendingRemove = folder
            }
        }
        #endif

        #if os(macOS)
        if isExpanded {
            projectChildren(folder, sessions: activeSessions, showingTerminal: showingTerminal)
        }
        #endif
    }

    #if os(macOS)
    private func projectChildren(
        _ folder: WorkspaceFolder,
        sessions: [TerminalSession],
        showingTerminal: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionRows(sessions, in: folder, showingTerminal: showingTerminal)
            ForEach(terminals.workspaceTerminals(in: folder.id).filter { $0.ssh != nil && $0.alive }) { session in
                SidebarRow(label: session.label, symbol: "server.rack",
                           isSelected: showingTerminal && terminals.activeTerminal(in: folder.id)?.id == session.id,
                           indent: 1) {
                    openSection(.sessions, in: folder.id) {
                        terminals.select(session, in: folder.id)
                    }
                }
                .contextMenu {
                    Button(L10n.text("apple.terminalpane.open_in_split.6b36cec3"), .compare) {
                        openSection(.sessions, in: folder.id) {
                            terminals.sendToOtherHalf(session, in: folder.id)
                        }
                    }
                }
            }
            chatHistoryRows(for: folder)
            ForEach(automations.liveJobs(in: folder.id)) { job in
                let run = automations.lastRun(for: job)
                ActiveAutomationRow(
                    job: job,
                    backendLabel: automations.backends
                        .first { $0.id == job.backend }?.label ?? job.backend,
                    isSelected: automations.selectedJobID == job.id
                        && (route.isGlobal(.automations)
                            || route == .workspace(id: folder.id, section: .automations))
                ) {
                    openAutomation(jobID: job.id, runID: run?.id, in: folder.id)
                }
            }
            ForEach(workflows.liveRuns(in: folder.id)) { run in
                ActiveWorkflowRow(
                    run: run,
                    isSelected: workflows.selectedRunID == run.id
                        && (route.isGlobal(.workflows)
                            || route == .workspace(id: folder.id, section: .workflows))
                ) {
                    openWorkflow(graphID: run.workflowID, runID: run.id, in: folder.id)
                }
            }
            if chat.sidebarChats(in: folder.id).isEmpty, terminals.workspaceTerminals(in: folder.id).isEmpty {
                Group {
                    switch chat.sidebarDirectoryPresentation(in: folder.id) {
                    case .loading:
                        Skeleton.Rows(count: 2, showsValue: false)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.text("apple.pullsview.loading.ba3bbbe1"))
                            .allowsHitTesting(false)
                    case .failed:
                        Button(L10n.text("common.retry"), .refresh) {
                            Task { await chat.warmWorkspacePreviews(folder.id, includeMessages: false) }
                        }.buttonStyle(QuietLinkStyle())
                    case .empty:
                        Text(L10n.text("apple.rootview.no_chats_yet.269208e4"))
                            .foregroundStyle(.tertiary)
                    case .content:
                        EmptyView()
                    }
                }
                .font(Theme.fit(12))
                .padding(.leading, Theme.Space.xl + Theme.Space.s)
                .padding(.trailing, Theme.Space.m)
                .padding(.vertical, 5)
            }
        }
        .task(id: SidebarChatReadIdentity(folderID: folder.id, model: ObjectIdentifier(chat),
                                         session: WorkSessionContext.shared.generation)) {
            guard chat.sidebarChats(in: folder.id).isEmpty, chat.folderID != folder.id else { return }
            await BridgeLaunch.wait()
            await chat.warmWorkspacePreviews(folder.id, includeMessages: false)
        }
    }

    @ViewBuilder
    private var liveServersSection: some View {
        let hosts = sshLiveHosts
        if !hosts.isEmpty {
            SidebarGroupHeader(title: L10n.text("apple.rootview.servers.68d7beb6"), count: hosts.count,
                               isExpanded: expandedSidebarSections.contains("servers")) {
                toggleSidebarSection("servers")
            } trailing: {
                sidebarSectionMenu()
            }
            if expandedSidebarSections.contains("servers") {
                ForEach(hosts) { host in
                    if sshSessions.sessions(for: host.id).isEmpty {
                        sshFavoriteHostRow(host)
                    } else {
                        sshLiveHostRow(host)
                    }
                }
            }
        }
    }

    private func toggleSidebarSection(_ section: String) {
        setSidebarSectionExpanded(section, !expandedSidebarSections.contains(section))
    }

    private func setSidebarSectionExpanded(_ section: String, _ expanded: Bool) {
        if expanded { expandedSidebarSections.insert(section) }
        else { expandedSidebarSections.remove(section) }
        SidebarPreferences.shared.rememberExpansion("section:" + section, expanded: expanded)
    }

    private func sidebarSectionMenu() -> some View {
        ToolbarMenuButton(help: L10n.text("common.sidebar.section_options"), diameter: Theme.Control.sidebarIcon, glyphSize: 12) {
            Button(L10n.text("common.sidebar.move_servers_above_projects"), .move) { moveSidebarSection("servers", before: "projects") }
                .disabled(sidebarSectionOrder.first == "servers")
            Button(L10n.text("common.sidebar.move_projects_above_servers"), .move) { moveSidebarSection("projects", before: "servers") }
                .disabled(sidebarSectionOrder.first == "projects")
        }
    }

    private func projectsSectionMenu() -> some View {
        ToolbarMenuButton(help: L10n.text("common.sidebar.section_options"), diameter: Theme.Control.sidebarIcon, glyphSize: 12) {
            if projectsDisplay == .byRepository {
                Section(L10n.text("common.sidebar.sort_section")) {
                    Picker(L10n.text("common.sidebar.sort_section"), selection: Binding(
                        get: { projectsSort },
                        set: { setProjectsSort($0) }
                    )) {
                        Label(L10n.text("common.sidebar.sort_manual"), systemImage: "hand.draw")
                            .tag(SidebarProjectsSort.manual)
                        Label(L10n.text("common.sidebar.sort_name"), systemImage: "textformat")
                            .tag(SidebarProjectsSort.name)
                        Label(L10n.text("common.sidebar.sort_recent"), systemImage: "clock")
                            .tag(SidebarProjectsSort.recent)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Section {
                if sidebarSectionOrder.first == "projects" {
                    Button(L10n.text("common.sidebar.move_servers_above_projects"), .move) { moveSidebarSection("servers", before: "projects") }
                } else {
                    Button(L10n.text("common.sidebar.move_projects_above_servers"), .move) { moveSidebarSection("projects", before: "servers") }
                }
            }
        }
    }

    private func projectsAddMenu() -> some View {
        ToolbarMenuButton(
            systemImage: "plus",
            help: L10n.text("common.sidebar.add_menu"),
            diameter: Theme.Control.sidebarIcon,
            glyphSize: 12
        ) {
            Button(L10n.text("apple.rootview.new_chat.db18382a"), .create) { startNewChat() }
            Menu(L10n.text("common.sidebar.new_chat_in")) {
                ForEach(workspaces.folders) { folder in
                    Button(folder.name, .reveal) { startNewChat(in: folder) }
                }
            }
            Section {
                Button(L10n.text("apple.rootview.add_a_project_folder.1fb6a975"), .reveal) {
                    workspaces.requestAdd()
                }
            }
        }
    }

    private func closeProjectsFilter() {
        projectsFilter = ""
        showingProjectsFilter = false
    }

    private func setProjectsDisplay(_ display: SidebarProjectsDisplay) {
        projectsDisplay = display
        SidebarPreferences.shared.projectsDisplay = display
    }

    private func setProjectsSort(_ sort: SidebarProjectsSort) {
        projectsSort = sort
        SidebarPreferences.shared.projectsSort = sort
    }

    private func openPull(_ pull: ChatPull, from folder: WorkspaceFolder) {
        guard pullFolder(pull, from: folder) != nil else {
            if let url = pull.webURL { openURL(url) }
            return
        }
        switch PullOpenPreference.shared.choice {
        case .ask:
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                pullToOpen = PendingPullOpen(pull: pull, folder: folder)
            }
        case let choice: openPull(pull, from: folder, in: choice)
        }
    }

    private func openPull(_ pull: ChatPull, from folder: WorkspaceFolder, in choice: PullOpenPreference.Choice) {
        if choice == .here, let target = pullFolder(pull, from: folder) {
            PullOpenRequest.shared.pending = .init(folderID: target.id, pull: pull)
            openSection(.pulls, in: target.id)
        } else if let url = pull.webURL {
            openURL(url)
        }
    }

    private func pullFolder(_ pull: ChatPull, from folder: WorkspaceFolder) -> WorkspaceFolder? {
        let own = Bridge.chatRoute(workspaceID: folder.id, peer: nil)
        return workspaces.folders.first {
            let route = Bridge.chatRoute(workspaceID: $0.id, peer: nil)
            return route.peer == own.peer && route.workspaceID == pull.workspaceId
        }
    }

    #if os(macOS)
    private func refreshSidebarPullMarks() async {
        var wait: Duration = .seconds(6)
        while !Task.isCancelled {
            do { try await Task.sleep(for: wait) } catch { return }
            wait = .seconds(60)
            for folder in workspaces.folders where chat.hasSidebarList(for: folder.id) {
                guard !Task.isCancelled else { return }
                guard Bridge.chatRoute(workspaceID: folder.id, peer: nil).peer == nil else { continue }
                await chat.warmWorkspacePreviews(folder.id, includeMessages: false)
            }
        }
    }
    #endif

    private func warmAllProjectChatLists(onlyUnread: Bool = false) async {
        chat.retainSidebarWorkspaceLists(workspaces.folders.map(\.id))
        await BridgeLaunch.wait()
        for folder in workspaces.folders {
            guard !Task.isCancelled else { return }
            if onlyUnread && chat.hasSidebarList(for: folder.id) { continue }
            await chat.warmWorkspacePreviews(folder.id, includeMessages: false)
        }
    }

    private func moveSidebarSection(_ section: String, before other: String) {
        SidebarPreferences.shared.move(section, before: other)
        sidebarSectionOrder = SidebarPreferences.shared.sectionOrder
    }

    private func setProjectExpanded(_ id: String, _ expanded: Bool) {
        if expanded { expandedWorkspaces.insert(id) } else { expandedWorkspaces.remove(id) }
        if expanded, !expandedSidebarSections.contains("projects") { setSidebarSectionExpanded("projects", true) }
        SidebarPreferences.shared.rememberExpansion("project:" + id, expanded: expanded)
    }

    private func setHistoryExpanded(_ id: String, _ expanded: Bool) {
        if expanded { expandedChatHistories.insert(id) } else { expandedChatHistories.remove(id) }
        SidebarPreferences.shared.rememberExpansion("history:" + id, expanded: expanded)
    }

    private func setServerExpanded(_ id: String, _ expanded: Bool) {
        if expanded { expandedSSHHosts.insert(id) } else { expandedSSHHosts.remove(id) }
        SidebarPreferences.shared.rememberExpansion("server:" + id, expanded: expanded)
    }
    #endif

    private var accountFooter: some View {
        VStack(spacing: 0) {
            OfflineCard(connectivity: connectivity, connection: connection)
            HostStatusCard()
            SyncCard(account: account)
            #if os(macOS)
            DeviceAccessCard(model: deviceRequests)
            #endif
            UpdateCard(update: appUpdate)
            sidebarAccountBar
        }
    }

    private var sidebarAccountBar: some View {
        SidebarAccountBar(
            name: account.signedIn ? (account.account?.title ?? L10n.text("common.account")) : L10n.text("common.sign_in"),
            detail: account.signedIn ? railAccountTier.map(PlanName.title) : nil,
            accessibilityLabel: railAccountLabel,
            menuItems: { accountMenuItems },
            settings: { navigate(to: .global(.account)) }
        )
    }

    #if os(macOS)
    private var accountMenuItems: [NativeMenuItem] {
        let checkUpdates = NativeMenuItem(
            appUpdate.isChecking ? L10n.text("apple.rootview.checking_for_updates.497a1998") : L10n.text("apple.rootview.check_for_updates.f26f3275"),
            isEnabled: !appUpdate.isChecking
        ) {
            Task { await appUpdate.checkNow() }
        }
        guard account.signedIn else {
            return [
                NativeMenuItem(L10n.text("apple.rootview.sign_in_to_tokenstat_ai.6276dc4d")) {
                    navigate(to: .global(.account))
                    account.signIn()
                },
                .separator,
                NativeMenuItem(L10n.text("common.account")) { navigate(to: .global(.account)) },
                .separator,
                checkUpdates,
            ]
        }
        return [
            NativeMenuItem(L10n.text("common.teams.title"), icon: .team) { navigate(to: .global(.team)) },
            .separator,
            NativeMenuItem(
                L10n.text("common.sync_now"),
                isEnabled: !account.isSyncing && account.syncCooldownUntil == nil
            ) {
                Task { await account.sync() }
            },
            .separator,
            checkUpdates,
            .separator,
            NativeMenuItem(L10n.text("common.sign_out")) { Task { await account.signOut() } },
            NativeMenuItem(L10n.text("apple.rootview.account_settings.a587aa1f")) { navigate(to: .global(.account)) },
        ]
    }
    #endif


    private var showsWorkspaceSurface: Bool {
        switch route.workspaceSection {
        case .sessions, .changes, .files, .browser: return true
        case .chat, .history, .pulls, .todo, .notes, .workflows, .automations, nil: return false
        }
    }

    private var showsChat: Bool { route.workspaceSection == .chat }

    private var chatFolder: String? {
        if case let .workspace(id: id, section: .chat) = route { return id }
        return mountedChatFolder
    }

    private var showsPulls: Bool { route.workspaceSection == .pulls }

    private var pullsFolder: String? {
        if case let .workspace(id, .pulls) = route { return id }
        return mountedPullsFolder
    }

    @ViewBuilder
    private var detail: some View {
        #if os(macOS)
        ZStack {
            WorkspacesView(
                model: workspaces,
                terminals: terminals,
                chat: chat,
                ssh: ssh,
                sshSessions: sshSessions,
                onManageServers: { openSSH(.hosts(folder: nil)) },
                onOpenSection: { section, folderID in
                    openSection(section, in: folderID) {
                        if section == .chat { showingChatOverview = true }
                    }
                },
                isActive: showsWorkspaceSurface,
                tier: account.account?.tier
            )
            .retainedPane(isActive: showsWorkspaceSurface)
            .opacity(showsWorkspaceSurface ? 1 : 0)
            .allowsHitTesting(showsWorkspaceSurface)
            .accessibilityHidden(!showsWorkspaceSurface)
            .zIndex(showsWorkspaceSurface ? 1 : 0)

            if let id = chatFolder {
                let folder = workspaces.folders.first { $0.id == id }
                ChatView(
                    model: chat,
                    workspaceID: id,
                    workspaceName: folder?.name,
                    git: folder?.git,
                    onBranchChanged: { await workspaces.refresh() },
                    onReviewChanges: { revealChanges(in: id, path: $0) },
                    onReviewTurnChanges: { changes, path in
                        desktopCommitReviews[id] = nil
                        desktopTurnReviews[id] = ChatTurnReview(changes: changes, focus: path,
                            conversation: chat.selected?.title ?? folder?.name ?? "")
                        openWorkbench(.changes, in: id)
                    },
                    onNewChat: { startNewChat(in: folder) },
                    showingOverview: $showingChatOverview,
                    isActive: showsChat,
                    showsConversationToolbarActions: showsConversationToolbarActions
                )
                .retainedPane(isActive: showsChat)
                .opacity(showsChat ? 1 : 0)
                .allowsHitTesting(showsChat)
                .accessibilityHidden(!showsChat)
                .zIndex(showsChat ? 2 : 0)
            }

            if let id = pullsFolder {
                let folder = workspaces.folders.first { $0.id == id }
                PullsView(
                    workspaceID: id,
                    connectionHostName: folder?.isRemote == true
                        ? L10n.text("apple.rootview.the_project_s_computer.7e755d17")
                        : nil,
                    workspaceName: folder.map {
                        $0.isRemote
                            ? "\($0.machineLabel ?? L10n.text("apple.rootview.remote.ffa98e02")) / \($0.name)"
                            : $0.name
                    },
                    workspaceIsRemote: folder?.isRemote == true,
                    isActive: showsPulls
                )
                .id(id)
                .retainedPane(isActive: showsPulls)
                .opacity(showsPulls ? 1 : 0)
                .allowsHitTesting(showsPulls)
                .accessibilityHidden(!showsPulls)
                .zIndex(showsPulls ? 2 : 0)
            }

            if !showsWorkspaceSurface {
                nonWorkspaceDetail
                    .zIndex(1)
            }
        }
        #else
        if showsWorkspaceSurface {
            WorkspacesView(model: workspaces)
        } else {
            nonWorkspaceDetail
        }
        #endif
    }

    /// Every destination except the workspace surface. On macOS the workspace
    /// surface is kept mounted separately so its terminals are not destroyed.
    @ViewBuilder
    private var nonWorkspaceDetail: some View {
        switch route {
        case .workspace(_, .sessions), .workspace(_, .changes),
             .workspace(_, .files), .workspace(_, .browser):
            EmptyView()
        case .workspace(_, .history):
            EmptyView()
        case let .workspace(id: id, section: .chat):
            #if os(macOS)
            EmptyView()
            #else
            let folder = workspaces.folders.first { $0.id == id }
            ChatView(
                model: chat,
                workspaceID: id,
                workspaceName: folder?.name,
                git: folder?.git,
                onBranchChanged: { await workspaces.refresh() },
                showingOverview: .constant(false)
            )
            #endif
        case let .workspace(id, .pulls):
            #if os(macOS)
            EmptyView()
            #else
            let folder = workspaces.folders.first { $0.id == id }
            PullsView(
                workspaceID: id,
                connectionHostName: folder?.isRemote == true
                    ? L10n.text("apple.rootview.the_project_s_computer.7e755d17")
                    : nil,
                workspaceName: folder.map {
                    $0.isRemote
                        ? "\($0.machineLabel ?? L10n.text("apple.rootview.remote.ffa98e02")) / \($0.name)"
                        : $0.name
                },
                workspaceIsRemote: folder?.isRemote == true
            )
            #endif
        case .global(.newChat):
            VStack(spacing: 0) {
                DetailChromeBar { EmptyView() }
                newChatPage
            }
        case .global(.home):
            HomeView(
                model: home,
                account: account,
                onShowAccount: { navigate(to: .global(.account)) },
                scanner: model,
                onOpenPin: openPin,
                pinAvailability: pinAvailability,
                pinSubtitle: pinSubtitle,
                recentWork: recentHomeWork,
                onOpenRecent: openHomeWork,
                onOpenMachine: { machine in
                    machines.selectAccount(machine)
                    navigate(to: .global(.machines))
                },
                setupHints: SetupHintsState(
                    signedIn: account.signedIn,
                    remoteAllowed: machines.remoteReachAllowed,
                    remoteOn: machines.status?.tunnel == true,
                    deviceCount: machines.accountMachines.count,
                    onSignIn: { account.signIn() },
                    onTurnOnRemote: { Task { await machines.setTunnel(true) } },
                    onOpenDevices: { navigate(to: .global(.machines)) },
                    onLoad: { await machines.load() }
                )
            )
        case .workspace(_, .automations), .global(.automations):
            AutomationsView(
                model: automations,
                folders: workspaces.folders,
                onNavigate: { handle($0) },
                pendingRunID: $pendingRunID
            )
        case .workspace(_, .workflows), .global(.workflows):
            WorkflowsView(
                model: workflows,
                folders: workspaces.folders
            )
        case .workspace(_, .todo), .global(.todo):
            TodoView(
                model: todo,
                folders: workspaces.folders,
                onViewRun: { runID, workspaceID in
                    openTaskRun(runID: runID, workspaceID: workspaceID)
                },
                onRunInFront: { launch in
                    launchTaskInFront(launch)
                }
            )
        case .workspace(_, .notes), .global(.notes):
            NotesView(
                model: todo,
                folders: workspaces.folders,
                workspaceID: route.workspaceID
            )
        case .global(.machines):
            MachinesView(model: machines, onNavigate: { handle($0) }, onInspect: {
                isInspectorPresented = true
                if !inspectorFits {
                    isOverlayVisible = true
                    overlayHeldByPress = true
                }
            }, onSignIn: {
                handle(.global(.account))
                account.signIn()
            })
        case .global(.team):
            TeamManagementView(store: teams, canCreateOrganization: railAccountTier == "legend", onAccount: { navigate(to: .global(.account)) }, transcript: TeamTranscriptContent.render)
        case .global(.account):
            AccountView(model: account)
        case .workspacesOverview:
            WorkspacesOverviewView(
                model: repositoryOverview,
                folders: workspaces.folders.filter { !$0.isGeneral },
                summaries: workspaces.summaries,
                directoryPresentation: workspaces.directoryPresentation,
                directoryError: workspaces.directoryError,
                isFullScreen: isFullScreen,
                peekShown: showsInspector || isOverlayVisible,
                onRetry: { Task { await workspaces.loadLocal() } },
                chatsIn: { id in chat.sidebarChats(in: id).filter { !chat.isUntouched($0, in: id) } },
                sessionsIn: { id in terminals.sessions(in: id).filter(\.alive).count },
                isAsleep: { folder in
                    folder.isRemote
                        && account.account?.machines.first { $0.publicIdentity == folder.machineID }?.online == false
                },
                sharedWith: { teams.sharedOrganizations(reported: $0.teamOrganizations, workspace: $0.id, isRemote: $0.isRemote) },
                refreshChats: { await chat.warmWorkspacePreviews($0.id, includeMessages: false) },
                actions: repositoryActions,
                onAdd: { workspaces.requestAdd() }
            )
        case let .ssh(section):
            #if os(macOS)
            SSHSectionView(
                model: ssh,
                section: section,
                vaultTier: machines.vaultTier,
                onOpenFolder: { openSSH(.hosts(folder: $0)) }
            )
            .id(ObjectIdentifier(ssh))
            #else
            EmptyView()
            #endif
        case let .sshTerminals(hostID):
            #if os(macOS)
            if let host = ssh.hosts.first(where: { $0.id == hostID }) {
                SSHTerminalPane(sessions: sshSessions, library: ssh, host: host)
            } else {
                EmptyState(
                    symbol: "server.rack",
                    title: L10n.text("apple.rootview.that_server_is_no_longer_saved.eb00734a"),
                    message: L10n.text("apple.rootview.any_session_still_running_on_it_is_listed.9386c35e")
                ) {
                    Button(L10n.text("apple.rootview.hosts.bba9af13"), .back) { openSSH(.hosts(folder: nil)) }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            #else
            EmptyView()
            #endif
        case .global(.insights):
            InsightsView(model: model, accountIdentity: (account.account?.host ?? "") + ":" + (account.account?.accountId ?? account.account?.handle ?? "signed-out")) {
                model.clearFocusedDay()
                navigate(to: .global(.home))
            }
        }
    }

    private func warmSecondarySurfaces() async {
        await Task.yield()
        guard !Task.isCancelled else { return }

        if !machines.isWarmed {
            await machines.load()
            connection.setPeerNames(machines.peers)
        }
        guard !Task.isCancelled else { return }

        #if os(macOS)
        await ssh.ensureLoaded(vaultTier: SSHLibraryModel.paidTier(for: machines.vaultTier))
        guard !Task.isCancelled else { return }
        #endif

        #if os(macOS)
        await LaunchCatalog.shared.resolve()
        #endif

        await automations.load()
        guard !Task.isCancelled else { return }
        await workflows.load()
    }

    private func openWorkflow(graphID: String, runID: String?, in folderID: String? = nil) {
        navigate(to: folderID.map { .workspace(id: $0, section: .workflows) } ?? .global(.workflows)) {
            workflows.selectGraph(graphID)
            if let runID, let run = workflows.runs.first(where: { $0.id == runID }) {
                workflows.selectRun(run)
            }
            isInspectorPresented = true
        }
    }

    private func openTaskRun(runID: String, workspaceID: String) {
        let route = TaskResultRoute(
            runID: runID, workspaceID: workspaceID, folders: workspaces.folders, hostName: "This computer"
        )
        switch route.runPlacement {
        case let .folderAutomations(id):
            navigate(to: .workspace(id: id, section: .automations))
        case .allAutomations:
            navigate(to: .global(.automations))
        }
        pendingRunID = runID
        isInspectorPresented = true
    }

    private func openTaskWorkspaceReview(workspaceID: String, surface: TaskResultWorkspaceSurface) {
        let route = TaskResultRoute(
            runID: pendingRunID ?? automations.selectedRun?.id ?? "",
            workspaceID: workspaceID,
            folders: workspaces.folders,
            hostName: "This computer"
        )
        guard route.canReviewWorkspace else { return }
        openSection(.changes, in: workspaceID) {
            workspaces.inspectorTab = surface == .history ? .history : .changes
            isInspectorPresented = true
        }
    }

    private func openAutomation(jobID: String, runID: String?, in folderID: String? = nil) {
        navigate(to: folderID.map { .workspace(id: $0, section: .automations) } ?? .global(.automations)) {
            automations.selectJob(jobID)
            if let runID, let run = automations.runs.first(where: { $0.id == runID }) {
                automations.selectRun(run)
            }
            pendingRunID = runID
            isInspectorPresented = true
        }
    }

    private func launchTaskInFront(_ launch: InteractiveTaskLaunch) {
        #if os(macOS)
        guard let folder = workspaces.folders.first(where: { $0.id == launch.workspaceID }) else {
            todo.errorMessage = L10n.text("apple.rootview.choose_a_project_first.090d7849")
            return
        }
        Task {
            do {
                let argv = try await Bridge.automationInteractiveCommand(
                    backend: launch.backend,
                    prompt: launch.prompt,
                    model: launch.model,
                    effort: launch.effort,
                    workspaceID: folder.id
                )
                guard let command = argv.first else {
                    todo.errorMessage = L10n.text("apple.rootview.the_agent_command_was_empty.793c23f6")
                    return
                }
                navigate(to: .workspace(id: folder.id, section: .sessions)) {
                    workspaces.selectedID = folder.id
                    workspaces.showTerminal(in: folder.id)
                    isInspectorPresented = true
                }
                let session = await terminals.start(
                    workspace: folder,
                    command: command,
                    args: Array(argv.dropFirst()),
                    profileID: LaunchAgentProfile.stored(for: folder.id)
                )
                if session == nil {
                    todo.errorMessage = terminals.errorMessage
                        ?? L10n.text("apple.rootview.could_not_start_a_terminal.6e9cc764")
                    return
                }
                if ["opencode", "opencode2"].contains(launch.backend),
                   argv.dropFirst().first == "--auto", argv.contains("--prompt"), let session {
                    let deadline = Date().addingTimeInterval(5)
                    while session.showsStartingState, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    session.sendEnter()
                }
                todo.noticeOpenedInFront(launch.title)
            } catch {
                todo.errorMessage = error.localizedDescription
            }
        }
        #endif
    }

    private func openTaskTerminal(_ info: PtySessionInfo) {
        #if os(macOS)
        guard let workspaceID = info.workspaceID,
              workspaces.folders.contains(where: { $0.id == workspaceID }) else {
            todo.errorMessage = L10n.text("apple.rootview.this_task_s_project_is_unavailable_the_run.af0a2ce5")
            return
        }
        _ = terminals.open(info)
        navigate(to: .workspace(id: workspaceID, section: .sessions)) {
            workspaces.selectedID = workspaceID
            workspaces.showTerminal(in: workspaceID)
            isInspectorPresented = true
        }
        #endif
    }

    #if os(macOS)
    private func projectActions(_ folder: WorkspaceFolder) -> [NativeMenuItem] {
        var items = SidebarPinAction.items(reference: pinReference(for: folder), name: folder.name, folderName: folder.name)
        if let reference = pinReference(for: folder) {
            items.append(.init(L10n.text("apple.rootview.saved_work_on_this_device.6942a15d"), icon: .archive) {
                savedFolder = .init(reference: reference, name: folder.name)
            })
        }
        items.append(.separator)
        if !folder.isRemote {
            if !teams.localProjects(for: folder.id).isEmpty {
                items.append(.init(L10n.text("common.teams.open_shared_project"), icon: .team) { openSharedProject(folder) })
                items.append(.init(L10n.text("common.teams.new_private_chat"), icon: .create) { startPrivateChat(in: folder) })
            }
            items.append(.init(L10n.text("common.teams.share_project"), icon: .connect) { sharingProject = folder })
            let shared = teams.localProjects.filter { $0.workspaceId == folder.id && ($0.phase == "active" || $0.accountCleanupPending) }
            if !shared.isEmpty {
                items.append(.init(L10n.text("common.teams.stop_sharing"), icon: .revoke, destructive: true) {
                    stoppingSharing = .init(name: folder.name, publications: shared)
                })
            }
            items.append(.separator)
        }
        if !folder.isRemote {
            items.append(.init(L10n.text("apple.rootview.reveal_in_finder.cc849385"), icon: .reveal) { workspaces.revealInFinder(folder) })
        } else if let peer = folder.machineID, !peer.isEmpty {
            items.append(.init(L10n.text("apple.rootview.disconnect_from_0.cc8c176c", "\(folder.machineLabel ?? L10n.text("apple.rootview.this_computer.058bf37c"))"), icon: .disconnect) {
                NotificationCenter.default.post(name: .remotePeerDidDisconnect, object: peer)
            })
        }
        if let peer = folder.machineID, workspaces.isRemoteStale(peer) { return items }
        items.append(.separator)
        items.append(.init(L10n.text("apple.rootview.new_chat.db18382a"), icon: .create) { startNewChat(in: folder) })
        items.append(.init(L10n.text("apple.rootview.new_terminal.9456c8eb"), icon: .create) {
            openSection(.sessions, in: folder.id) { workspaces.showLauncher(in: folder.id) }
        })
        if folder.git?.isRepo == true {
            items.append(.init(L10n.text("apple.rootview.worktrees.c336cb52"), icon: .source) { worktreeProject = folder })
        }
        items.append(.init(L10n.text("apple.rootview.delete_all_chats.9753e785"), icon: .delete, destructive: true) { workspacePendingChatRemoval = folder })
        items.append(.separator)
        items.append(.init(L10n.text("apple.rootview.remove_from_tokenstat.195e6064"), icon: .delete, destructive: true) { workspacePendingRemove = folder })
        return items
    }

    private func openSharedProject(_ folder: WorkspaceFolder) {
        let publications = teams.localProjects(for: folder.id)
        guard publications.count == 1, let publication = publications.first else { sharingProject = folder; return }
        let openingRoute = route, owner = teams.owner
        Task {
            let opened = await teams.openLocalProject(publication)
            guard route == openingRoute, teams.owner == owner else { return }
            if !opened { teams.showProjects() }
            navigate(to: .global(.team))
        }
    }

    private func duplicateTerminal(_ session: TerminalSession, in folder: WorkspaceFolder) {
        let scope = WorkSessionContext.shared.scope
        Task {
            let catalog = LaunchCatalog.shared
            let peer = Bridge.chatRoute(workspaceID: folder.id).peer
            if let peer { await catalog.resolveRemote(peer: peer) }
            else { await catalog.resolve() }
            guard scope == WorkSessionContext.shared.scope else { return }
            let profiles = peer.map { catalog.remoteAvailable(for: $0) } ?? catalog.available
            guard let shell = profiles.first(where: { $0.id == "shell" }) ?? (peer == nil ? .shellFallback : nil) else {
                terminals.errorMessage = L10n.text("apple.rootview.reconnect_the_project_s_computer_to_open_a.5d2cf5ef")
                return
            }
            openSection(.sessions, in: folder.id)
            if let copy = await terminals.start(workspace: folder, command: shell.command,
                                                args: shell.args, rows: session.rows, cols: session.cols) {
                SidebarTerminalNames.shared.rename(copy.workReference, to: L10n.text("apple.rootview.0_copy.c242571e", "\(session.customName ?? L10n.text("apple.rootview.shell.a7332854"))"),
                                                   folderName: folder.name)
            }
        }
    }
    #endif

    private var workspaceInsertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(height: 2)
            .padding(.horizontal, Theme.Space.m)
    }

    #if os(macOS)
    @ViewBuilder
    private func sessionRows(
        _ sessions: [TerminalSession],
        in folder: WorkspaceFolder,
        showingTerminal: Bool
    ) -> some View {
        ForEach(sessions) { session in
            ActiveSessionRow(
                session: session,
                folder: folder,
                duplicate: { duplicateTerminal(session, in: folder) },
                isSelected: showingTerminal
                    && terminals.active(in: folder.id)?.id == session.id,
                close: {
                    if session.alive {
                        sessionPendingClose = session
                    } else {
                        Task { await terminals.close(session) }
                    }
                }
            ) {
                openSection(.sessions, in: folder.id) {
                    terminals.select(session)
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private func chatHistoryRows(for folder: WorkspaceFolder) -> some View {
        let all = chat.sidebarChats(in: folder.id).filter { !chat.isUntouched($0, in: folder.id) }
        let list = SidebarProjectsLayout.matches(projectsFilter, folder: folder, chats: [])
            ? all
            : SidebarProjectsLayout.filteredChats(all, query: projectsFilter)
        if list.isEmpty {
            EmptyView()
        } else {
            chatHistoryList(for: folder, conversations: list)
        }
    }

    @ViewBuilder
    private func chatHistoryList(for folder: WorkspaceFolder, conversations incoming: [ChatConversation]) -> some View {
        let conversations = Self.holdingOrder(incoming, held: chatOrderHold.order[folder.id])
        let isCurrent = chat.folderID == folder.id
        let expanded = expandedChatHistories.contains(folder.id)
        let selectedIndex = conversations.firstIndex { $0.id == chat.selected?.id }
        let window = ChatHistoryWindow.visible(
            count: conversations.count, selected: selectedIndex, expanded: expanded
        )
        let visible = Array(conversations[window])
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { conversation in
                ChatSidebarConversationRow(
                    conversation: conversation,
                    folder: folder,
                    rename: { try await chat.rename(conversation, in: folder.id, to: $0) },
                    fork: {
                        let previousRoute = route
                        let copied = try await chat.fork(conversation, in: folder.id)
                        if route == previousRoute {
                            chat.reveal(id: copied.id, in: folder.id)
                            setProjectExpanded(folder.id, true)
                            setHistoryExpanded(folder.id, true)
                            openSection(.chat, in: folder.id)
                        }
                    },
                    draft: chat.draftReference(for: conversation.id, in: folder.id),
                    runningSince: chat.turnStartedAt(for: conversation.id),
                    isSelected: chat.selected?.id == conversation.id
                        && !showingChatOverview
                        && route == .workspace(id: folder.id, section: .chat),
                    select: {
                        if isCurrent {
                            openSection(.chat, in: folder.id) {
                                Task { await chat.select(conversation) }
                            }
                        } else {
                            chat.reveal(id: conversation.id, in: folder.id)
                            openSection(.chat, in: folder.id)
                        }
                    },
                    remove: {
                        Task { await chat.remove(conversation, in: folder.id) }
                    },
                    openPull: { openPull($0, from: folder) },
                    warmPreview: { await chat.warmConversationPreview(conversation, in: folder.id) },
                    folderIsOpen: isCurrent
                )
                .equatable()
                .id(Self.sidebarChatRowID(conversation.id))
            }
            if conversations.count > ChatHistoryWindow.collapsedLimit {
                HStack {
                    Button(expanded ? L10n.text("apple.rootview.show_less.94ea9b1d") : L10n.text("apple.rootview.show_0_more.b91c3640", "\(min(conversations.count, ChatHistoryWindow.inlineLimit) - window.count)")) {
                        if expanded {
                            setHistoryExpanded(folder.id, false)
                        } else {
                            setHistoryExpanded(folder.id, true)
                        }
                    }
                    .buttonStyle(QuietLinkStyle())
                    .font(Theme.fit(12, weight: .medium))
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Space.s)
                    if conversations.count > ChatHistoryWindow.inlineLimit {
                        Button(L10n.text("apple.rootview.see_all_chats.e705024a"), .search) {
                            openSection(.chat, in: folder.id) {
                                showingChatOverview = true
                            }
                        }
                        .buttonStyle(QuietLinkStyle())
                        .font(Theme.fit(12, weight: .medium))
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, ChatSidebarConversationRow.titleInset)
                .padding(.trailing, Theme.Space.m)
                .frame(height: DisplayFit.dp(Theme.Control.sidebarRow))
            }
        }
        .onHover { inside in
            chatOrderHold.order[folder.id] = inside ? conversations.map(\.id) : nil
        }
        .onDisappear { chatOrderHold.order[folder.id] = nil }
        .onChange(of: chat.selected?.id) { _, selectedID in
            guard let selectedID,
                  let index = conversations.firstIndex(where: { $0.id == selectedID }),
                  index >= ChatHistoryWindow.collapsedLimit
            else { return }
            setHistoryExpanded(folder.id, true)
        }
    }

    final class ChatOrderHold {
        var order: [String: [String]] = [:]
    }

    static func holdingOrder(_ list: [ChatConversation], held: [String]?) -> [ChatConversation] {
        guard let held else { return list }
        let rank = Dictionary(held.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = list.filter { rank[$0.id] != nil }
            .sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        return known + list.filter { rank[$0.id] == nil }
    }

    private func count(of section: WorkspaceSection, in folder: WorkspaceFolder) -> Int? {
        let remote = folder.isRemote ? workspaces.summary(for: folder.id) : nil
        let value: Int
        switch section {
        case .sessions: value = terminals.workspaceTerminals(in: folder.id).filter(\.alive).count
        case .chat:
            if chat.folderID == folder.id || chat.workspaceID == folder.id {
                value = chat.chats.count
            } else {
                value = workspaces.summary(for: folder.id)?.chats ?? 0
            }
        case .changes: value = folder.git?.files.count ?? 0
        case .history: return nil
        case .pulls: value = remote?.pulls ?? pullCounts.count(key: folder.id) ?? 0
        case .todo: value = remote?.tasks ?? todo.openCount(in: folder.id)
        case .notes:
            value = folder.isRemote ? 0 : todo.noteCount(in: folder.id)
        case .workflows:
            if let remote {
                value = remote.workflowsRunning > 0 ? remote.workflowsRunning : remote.workflows
            } else {
                value = workflows.count(in: folder.id)
            }
        case .automations: value = remote?.automations ?? automations.count(in: folder.id)
        case .files: return nil
        case .browser: value = workspaces.browserTabs(in: folder.id).count
        }
        return value > 0 ? value : nil
    }

    #if os(macOS)
    private func openSSH(_ section: SSHSection) {
        navigate(to: .ssh(section)) {
            if route.sshSection?.row != section.row { ssh.selection = nil }
            lastSSHSection = section
        }
    }

    #endif

    private func openSection(
        _ section: WorkspaceSection,
        in folderID: String,
        revealInSidebar: Bool = true,
        then update: (() -> Void)? = nil
    ) {
        navigate(to: .workspace(id: folderID, section: section)) {
            #if os(macOS)
            if section == .chat { showingChatOverview = false }
            #endif
            workspaces.selectedID = folderID
            lastSection[folderID] = section
            if revealInSidebar { setProjectExpanded(folderID, true) }
            #if os(macOS)
            switch section {
            case .sessions: workspaces.showTerminal(in: folderID)
            case .changes: workspaces.reviewWorkingTree(in: folderID)
            case .files: workspaces.showFiles(in: folderID)
            case .browser:
                let existing = workspaces.tabs(in: folderID).last {
                    if case .browser = $0 { return true }
                    return false
                }
                if let existing {
                    workspaces.show(existing, in: folderID)
                } else {
                    workspaces.showBrowser(in: folderID)
                }
            case .chat, .history, .pulls, .todo, .notes, .workflows, .automations:
                break
            }
            #endif
            update?()
        }
    }

    private func pinReference(for folder: WorkspaceFolder) -> WorkReference? {
        guard let scope = WorkSessionContext.shared.scope else { return nil }
        let resolved = WorkDestinationResolver.route(folderID: folder.id)
        guard let host = resolved.peer ?? WorkSessionContext.shared.localHostIdentity,
              !resolved.workspaceID.isEmpty
        else { return nil }
        return WorkReference(scope: scope, hostIdentity: host,
                             workspaceID: resolved.workspaceID,
                             kind: .workspace, itemID: nil)
    }

    private var recentHomeWork: [DesktopHomeDestination] {
        guard let scope = WorkSessionContext.shared.scope else { return [] }
        let folderIDs = workspaces.folders.map(\.id)
        return WorkContinuityStore.shared.recentConversations(scope: scope).compactMap { reference in
            switch desktopAvailability(reference) {
            case .hostRemoved, .itemDeleted: return nil
            default: break
            }
            let folderID = WorkPlaceRestoration.folderID(
                for: reference, among: folderIDs,
                localHostIdentity: WorkSessionContext.shared.localHostIdentity
            )
            let folder = workspaces.folders.first { $0.id == folderID }
            let conversation = folderID.flatMap { id in
                chat.sidebarChats(in: id).first { $0.id == reference.itemID }
            }
            if let conversation, let folderID, chat.isUnused(conversation, in: folderID) { return nil }
            let title = conversation?.title
            let machine = reference.hostIdentity == WorkSessionContext.shared.localHostIdentity
                ? L10n.text("apple.rootview.this_mac.79a4aefc") : folder?.machineLabel ?? L10n.text("apple.rootview.remote_machine.d9dd1af3")
            return DesktopHomeDestination(
                reference: reference, title: title ?? L10n.text("apple.rootview.conversation_in_0.ad84a8f5", "\(folder?.name ?? L10n.text("apple.rootview.a_previous_folder.b0435053"))"),
                subtitle: "\(folder?.name ?? L10n.text("apple.rootview.folder.74ccd433")) · \(machine)",
                unavailable: workAvailabilityMessage(reference)
            )
        }
    }

    private func openSearchWork(_ reference: WorkReference) -> Bool {
        guard let scope = WorkSessionContext.shared.scope, reference.scope == scope,
              let local = WorkSessionContext.shared.localHostIdentity,
              reference.hostIdentity == local || WorkAccessStore.shared.allowed(scope: scope, host: reference.hostIdentity) == true else { return false }
        if reference.kind == .conversation, savedWorkCatalog.contains(reference),
           desktopAvailability(reference) == .savedCopy {
            savedConversation = .init(reference: reference)
            return true
        }
        guard let folderID = WorkPlaceRestoration.folderID(for: reference, among: workspaces.folders.map(\.id),
                                                          localHostIdentity: local) else { return false }
        if reference.kind == .conversation {
            guard workAvailabilityMessage(reference) == nil else { return false }
            if let anchor = reference.anchor, ChatReadingMark.isStable(eventID: anchor) {
                ChatReadingStore.shared.request(.init(eventID: anchor, offset: 0, updatedAt: Date(), revealTarget: true), for: reference)
            }
            chat.restoreSearchReadingPosition(reference)
            openHomeWork(reference)
        } else if reference.kind == .workspace {
            openSection(lastSection[folderID] ?? .chat, in: folderID)
        } else { return false }
        return true
    }

    private func openHomeWork(_ reference: WorkReference) {
        guard workAvailabilityMessage(reference) == nil else { return }
        if desktopAvailability(reference) == .savedCopy {
            savedConversation = .init(reference: reference)
            return
        }
        guard reference.scope == WorkSessionContext.shared.scope,
              let folderID = WorkPlaceRestoration.folderID(
                for: reference, among: workspaces.folders.map(\.id),
                localHostIdentity: WorkSessionContext.shared.localHostIdentity
              ), let item = reference.itemID else { return }
        chat.reveal(id: item, in: folderID)
        setProjectExpanded(folderID, true)
        setHistoryExpanded(folderID, true)
        openSection(.chat, in: folderID)
    }

    private func pinSubtitle(_ pin: PinnedWorkStore.Pin) -> String {
        let folderID = WorkPlaceRestoration.folderID(
            for: pin.reference, among: workspaces.folders.map(\.id),
            localHostIdentity: WorkSessionContext.shared.localHostIdentity
        )
        let folder = workspaces.folders.first { $0.id == folderID }
        let machine = pin.reference.hostIdentity == WorkSessionContext.shared.localHostIdentity
            ? L10n.text("apple.rootview.this_mac.79a4aefc") : folder?.machineLabel ?? L10n.text("apple.rootview.remote_machine.d9dd1af3")
        return pin.reference.kind == .workspace ? machine : "\(pin.folderName) · \(machine)"
    }

    private func desktopAvailability(_ reference: WorkReference) -> WorkDestinationResolver.Availability {
        let local = reference.hostIdentity == WorkSessionContext.shared.localHostIdentity
        let machine = account.account?.machines.first { $0.publicIdentity == reference.hostIdentity }
        let folder = WorkPlaceRestoration.folderID(for: reference, among: workspaces.folders.map(\.id),
                                                   localHostIdentity: WorkSessionContext.shared.localHostIdentity)
        return WorkDestinationResolver.availability(.init(
            accountVerified: reference.scope == WorkSessionContext.shared.scope,
            hostLinked: local || machine != nil,
            accessAllowed: local ? true : WorkAccessStore.shared.allowed(scope: reference.scope, host: reference.hostIdentity),
            connected: folder != nil && (local || machine?.online == true),
            savedCopy: savedWorkCatalog.contains(reference)))
    }

    private func workAvailabilityMessage(_ reference: WorkReference) -> String? {
        switch desktopAvailability(reference) {
        case .live, .savedCopy: nil
        case .accessRequired: L10n.text("apple.rootview.verify_this_account_and_its_project_access.e7a9f207")
        case .hostRemoved: L10n.text("apple.rootview.this_machine_is_no_longer_linked.b502d162")
        case .itemDeleted: L10n.text("apple.rootview.this_work_is_no_longer_available.81259506")
        case .unsupportedHost: L10n.text("apple.rootview.update_the_host_to_open_this_work.596b980e")
        case .reconnecting: L10n.text("apple.rootview.reconnecting_to_the_machine.ff19692f")
        case .unavailable: L10n.text("apple.rootview.connect_the_machine_and_open_its_folder_in.04907021")
        }
    }

    private func pinAvailability(_ pin: PinnedWorkStore.Pin) -> String? {
        if let message = workAvailabilityMessage(pin.reference) { return message }
        #if os(macOS)
        if pin.reference.kind == .terminal, terminalForPin(pin) == nil {
            return L10n.text("apple.rootview.this_terminal_session_has_ended.022b26e2")
        }
        #endif
        return nil
    }

    #if os(macOS)
    private func terminalForPin(_ pin: PinnedWorkStore.Pin) -> TerminalSession? {
        guard let folderID = WorkPlaceRestoration.folderID(for: pin.reference,
            among: workspaces.folders.map(\.id), localHostIdentity: WorkSessionContext.shared.localHostIdentity)
        else { return nil }
        return terminals.sessions(in: folderID).first { $0.hostID == pin.reference.itemID }
    }
    #endif

    private func openPin(_ pin: PinnedWorkStore.Pin) {
        guard pinAvailability(pin) == nil else { return }
        if desktopAvailability(pin.reference) == .savedCopy {
            savedConversation = .init(reference: pin.reference)
            return
        }
        let ids = workspaces.folders.map(\.id)
        guard let folderID = WorkPlaceRestoration.folderID(
            for: pin.reference, among: ids,
            localHostIdentity: WorkSessionContext.shared.localHostIdentity
        ) else { return }
        if WorkDestinationResolver.route(folderID: folderID).peer != nil {
            guard WorkSessionContext.shared.scope == pin.reference.scope else { return }
        }
        switch pin.reference.kind {
        case .workspace:
            openSection(lastSection[folderID] ?? .chat, in: folderID)
        case .conversation:
            guard let item = pin.reference.itemID, !item.isEmpty else { return }
            chat.reveal(id: item, in: folderID)
            setProjectExpanded(folderID, true)
            setHistoryExpanded(folderID, true)
            openSection(.chat, in: folderID)
        case .terminal:
            #if os(macOS)
            guard let session = terminalForPin(pin) else { return }
            setProjectExpanded(folderID, true)
            openSection(.sessions, in: folderID) { terminals.select(session) }
            #endif
        case .commit, .savedDiff:
            return
        }
    }

    #if os(macOS)
    private var repositoryActions: RepositoryActions {
        RepositoryActions(
            open: { selectWorkspace($0) },
            section: { section, id in openSection(section, in: id) },
            newChat: { id in startNewChat(in: workspaces.folders.first { $0.id == id }) },
            chat: { chatID, id in
                chat.reveal(id: chatID, in: id)
                setHistoryExpanded(id, true)
                openSection(.chat, in: id)
            },
            pull: { number, id in
                guard let folder = workspaces.folders.first(where: { $0.id == id }),
                      let pulls = repositoryOverview.pulls[id],
                      let pull = pulls.open.first(where: { $0.number == number }) else {
                    openSection(.pulls, in: id)
                    return
                }
                let route = Bridge.chatRoute(workspaceID: id, peer: nil)
                openPull(ChatPull(pull, url: pulls.webBase.map { "\($0)/pull/\(number)" } ?? "",
                                  workspaceID: route.workspaceID), from: folder, in: .here)
            },
            file: { path, id in
                openSection(.changes, in: id) {
                    workspaces.focusWorkingTree(in: id, path: path)
                }
            },
            peek: { id in
                if repositoryOverview.peekID == id, showsInspector || isOverlayVisible {
                    repositoryOverview.peekID = nil
                    closeInspector()
                    return
                }
                repositoryOverview.peekID = id
                isInspectorPresented = true
                if !inspectorFits {
                    isOverlayVisible = true
                    overlayHeldByPress = true
                }
            }
        )
    }
    #endif

    private func selectWorkspace(_ id: String, revealInSidebar: Bool = true) {
        navigate(to: .workspace(id: id, section: .sessions)) {
            workspaces.selectedID = id
            lastSection[id] = .sessions
            if revealInSidebar { setProjectExpanded(id, true) }
            #if os(macOS)
            workspaces.showLauncher(in: id)
            #endif
        }
    }

    private func rememberPlace(_ next: Route) {
        let store = WorkContinuityStore.shared
        switch next {
        case let .global(section):
            store.rememberPlace(.global(section.rawValue))
        case let .workspace(id, section):
            guard let scope = WorkSessionContext.shared.scope else { return }
            let resolved = WorkDestinationResolver.route(folderID: id)
            guard let host = resolved.peer ?? WorkSessionContext.shared.localHostIdentity,
                  let place = WorkPlace.workspace(
                      WorkReference(scope: scope, hostIdentity: host,
                                    workspaceID: resolved.workspaceID,
                                    kind: .workspace, itemID: nil),
                      section: section.rawValue
                  ) else { return }
            store.rememberPlace(place)
        case .workspacesOverview, .ssh, .sshTerminals:
            store.forgetPlace()
        }
    }

    private func settleLaunchPlace() async {
        defer { placeSettled = true }
        await BridgeLaunch.wait()
        guard !ecosystemNavigation.hasRequestedNavigation, WorkPlaceLaunch.claim(), LaunchPreferences.restoresLocation, let stored = WorkContinuityStore.shared.place() else { return }
        if let section = stored.globalSection {
            if let global = GlobalSection(rawValue: section), global != .account {
                navigate(to: .global(global))
            }
            return
        }
        await WorkSessionContext.shared.resolveLocalHostIdentity()
        let deadline = ContinuousClock.now + Self.placeDeadline
        let folderIsRemote = stored.folder?.hostIdentity != WorkSessionContext.shared.localHostIdentity
        if folderIsRemote {
            while WorkSessionContext.shared.scope == nil {
                guard ContinuousClock.now < deadline else { return }
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
            }
            Task { await workspaces.loadRemote() }
        }
        while ContinuousClock.now < deadline {
            let destination = WorkPlaceRestoration.destination(
                place: stored,
                folderIDs: workspaces.folders.map(\.id),
                scope: WorkSessionContext.shared.scope,
                localHostIdentity: WorkSessionContext.shared.localHostIdentity
            )
            if case let .workspace(folderID, name)? = destination,
               let section = WorkspaceSection(rawValue: name) {
                Logger(subsystem: "ai.tokenstat.tokenstat", category: "chatload")
                    .error("restoring section=\(name) folder=\(folderID)")
                openSection(section, in: folderID, revealInSidebar: false)
                return
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
        }
    }

    private static let placeDeadline: Duration = .milliseconds(1400)

    /// Go somewhere, and apply the state that arrival needs, in one
    /// un-animated transaction.
    ///
    /// Two state changes SwiftUI is free to animate separately are two things
    /// the user sees move at different times: the inspector visibly trailed
    /// the row it belongs to.
    private func navigate(to next: Route, update: (() -> Void)? = nil) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            route = next
            rememberPlace(next)
            #if os(macOS)
            if case let .workspace(id: id, section: .chat) = next { mountedChatFolder = id }
            if case let .workspace(id, .pulls) = next { mountedPullsFolder = id }
            #endif
            applyScope(from: next)
            update?()
        }
    }

    private func applyScope(from next: Route) {
        let previous = todo.scope
        let nextID = next.workspaceID
        todo.scope = nextID
        automations.scope = nextID
        workflows.scope = nextID
        if previous != nextID {
            todo.dropOutOfScopeSelection()
            automations.dropOutOfScopeSelection()
            workflows.dropOutOfScopeSelection()
        }
    }

    private func refreshAfterSync() {
        Task { await home.reloadAfterSync() }
        model.reload()
    }

    private func syncRouteToFront(_ front: WorkspaceSurface) {
        guard let id = route.workspaceID, let section = route.workspaceSection else { return }
        switch section {
        case .chat:
            switch front {
            case .file, .commit, .changes:
                navigate(to: .workspace(id: id, section: .sessions))
            default: break
            }
        case .files, .changes, .browser:
            if front == .sessions || front == .launcher {
                lastSection[id] = .sessions
                navigate(to: .workspace(id: id, section: .sessions))
            }
        default:
            break
        }
    }

    private func openEcosystemDestination() {
        guard placeSettled, let target = ecosystemNavigation.pending else { return }
        if target.projectID != nil {
            guard WorkSessionContext.shared.scope != nil, !workspaces.isLoading else { return }
        }
        ecosystemNavigation.pending = nil
        if target.screen != .search { showWorkSearch = false }
        switch target.screen {
        case .search:
            ecosystemSearchTerm = target.searchTerm ?? ""
            showWorkSearch = true
        case .account: navigate(to: .global(.account))
        case .ssh: navigate(to: .ssh(.hosts(folder: nil)))

        case .home: navigate(to: .global(.home))
        case .insights: navigate(to: .global(.insights))
        case .machines: navigate(to: .global(.machines))
        case .workspaces:
            guard let id = target.projectID,
                  target.owner == EcosystemPublisher.ownerKey(WorkSessionContext.shared.scope),
                  workspaces.folders.contains(where: { $0.id == id && $0.exists }) else {
                navigate(to: .workspacesOverview)
                return
            }
            openSection(WorkspaceSection(rawValue: target.section?.rawValue ?? "sessions") ?? .sessions, in: id)
        }
    }

    private func openPendingNotification() {
        guard let request = notificationOpen.request else { return }
        if openFromNotification(request) {
            _ = notificationOpen.take()
            return
        }
        if notificationOpen.dropIfStale() { landAfterFailedTap() }
    }

    private func openFromNotification(_ request: NotificationOpen.Request) -> Bool {
        if let session = sessionMatching(request) {
            openSection(.sessions, in: session.workspaceID) {
                terminals.select(session)
            }
            return true
        }
        guard request.kind == .chat, let conversationID = request.conversationID, !conversationID.isEmpty else {
            return false
        }
        let folderID = request.workspaceID.flatMap { workspaceID in
            workspaces.folders.first { $0.id == workspaceID }?.id
        } ?? chat.folderID ?? workspaces.selectedID ?? workspaces.folders.first?.id
        guard let folderID, !folderID.isEmpty else { return false }
        if chat.selected?.id == conversationID, showsChat, chatFolder == folderID {
            return true
        }
        chat.reveal(id: conversationID, in: folderID)
        setProjectExpanded(folderID, true)
        setHistoryExpanded(folderID, true)
        openSection(.chat, in: folderID) {
            Task {
                guard chat.folderID == folderID,
                      chat.selected?.id != conversationID,
                      let conversation = chat.chats.first(where: { $0.id == conversationID })
                else { return }
                await chat.select(conversation)
            }
        }
        return true
    }

    private func landAfterFailedTap() {
        guard let id = workspaces.selectedID ?? workspaces.folders.first?.id,
              !id.isEmpty
        else { return }
        openSection(.sessions, in: id)
    }

    private func sessionMatching(_ request: NotificationOpen.Request) -> TerminalSession? {
        if let id = request.sessionID, !id.isEmpty {
            return terminals.sessions.first(where: { $0.id == id })
        }
        if request.kind == .chat, let conversationID = request.conversationID,
           !conversationID.isEmpty {
            return nil
        }
        return terminals.sessions.first { $0.state == .needsAttention }
    }

    private func handle(_ request: NavigationRequest) {
        switch request {
        case let .global(section):
            navigate(to: .global(section))
        case .ssh:
            #if os(macOS)
            openSSH(lastSSHSection)
            #endif
        case .workspaces:
            guard let id = workspaces.selectedID ?? workspaces.folders.first?.id else { return }
            openSection(.sessions, in: id)
        case .workspacesOverview:
            navigate(to: .workspacesOverview)
        case .launcher:
            guard let id = workspaces.selectedID ?? workspaces.folders.first?.id else { return }
            selectWorkspace(id)
        }
    }
}

private struct RemoveWorkspaceConfirm: View {
    @Binding var folder: WorkspaceFolder?
    var remove: (WorkspaceFolder) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                L10n.text("apple.rootview.remove_from_tokenstat.ab2e2b74"),
                isPresented: Binding(
                    get: { folder != nil },
                    set: { if !$0 { folder = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.text("common.remove"), role: .destructive) {
                    if let folder {
                        remove(folder)
                    }
                    folder = nil
                }
                Button(L10n.text("apple.rootview.keep_it.fdce5da2"), role: .cancel) {
                    folder = nil
                }
            } message: {
                Text(
                    L10n.text("apple.rootview.remove_0_from_the_sidebar_the_folder_on_di.aef7692a", "\(folder?.name ?? L10n.text("apple.rootview.this_folder.9d6325c8"))")
                )
            }
    }
}

private struct RemoveAllChatsConfirm: View {
    @Binding var folder: WorkspaceFolder?
    var remove: (WorkspaceFolder) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                L10n.text("apple.rootview.remove_every_chat.fc1af6bd"),
                isPresented: Binding(
                    get: { folder != nil },
                    set: { if !$0 { folder = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.text("apple.rootview.remove_all_chats.c32cefb3"), role: .destructive) {
                    if let folder { remove(folder) }
                    folder = nil
                }
                Button(L10n.text("common.cancel"), role: .cancel) { folder = nil }
            } message: {
                Text(L10n.text("apple.rootview.this_permanently_deletes_every_chat_transc.1579eb9d", "\(folder?.name ?? L10n.text("apple.rootview.this_project.11453073"))"))
            }
    }
}

#if os(macOS)
private struct CloseSessionConfirm: View {
    @Binding var session: TerminalSession?
    var close: (TerminalSession) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                L10n.text("apple.rootview.stop_this_session.5efe50c8"),
                isPresented: Binding(
                    get: { session != nil },
                    set: { if !$0 { session = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.text("apple.rootview.stop_and_close.52b40c33"), role: .destructive) {
                    if let session {
                        close(session)
                    }
                    session = nil
                }
                Button(L10n.text("common.cancel"), role: .cancel) { session = nil }
            } message: {
                Text(L10n.text("apple.rootview.the_process_will_be_killed_a_stopped_sessi.bf3e9249"))
            }
    }
}

private struct CloseSSHSessionsConfirm: View {
    @Binding var host: SSHHost?
    var sessionCount: (SSHHost) -> Int
    var close: (SSHHost) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                L10n.text("apple.rootview.close_every_session_on_this_server.306d4ecd"),
                isPresented: Binding(
                    get: { host != nil },
                    set: { if !$0 { host = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.text("apple.rootview.close_all.5d1552a8"), role: .destructive) {
                    if let host {
                        close(host)
                    }
                    host = nil
                }
                Button(L10n.text("common.cancel"), role: .cancel) { host = nil }
            } message: {
                Text(message)
            }
    }

    private var message: String {
        guard let host else { return "" }
        let count = sessionCount(host)
        let noun = count == 1 ? "session" : "sessions"
        return L10n.text("apple.rootview.close_0_1_on_2_anything_still_running_in_t.402ac91d", "\(count)", "\(noun)", "\(host.label)")
    }
}


#endif

private struct SidebarRow: View {
    var label: String
    var symbol: String
    var symbolSize: CGFloat = 13
    var trailing: String?
    var isSelected: Bool
    var indent: Int = 0
    var folderMetrics = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(label: label, symbol: symbol, symbolSize: symbolSize, trailing: trailing,
                            isSelected: isSelected, indent: indent, isHovering: isHovering,
                            folderMetrics: folderMetrics)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SidebarRowLabel: View {
    var label: String
    var symbol: String
    var symbolSize: CGFloat = 13
    var trailing: String?
    var isSelected: Bool
    var indent: Int = 0
    var isHovering: Bool
    var folderMetrics = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if indent > 0 {
                Spacer(minLength: 0).frame(width: CGFloat(indent) * 14)
            }
            Image(systemName: symbol)
                .font(Theme.fit(symbolSize))
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                .frame(width: 18)
            Text(label)
                .font(Theme.fit(13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            if let trailing, trailing != "0" {
                Text(trailing)
                    .font(Theme.numeric(11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, folderMetrics ? Theme.Space.s : Theme.Space.m)
        .padding(.vertical, folderMetrics ? 0 : 5)
        .frame(height: folderMetrics ? DisplayFit.dp(Theme.Control.sidebarRow) : nil)
        .background(background)
        .contentShape(.rect)
    }

    private var background: some View {
        SidebarRowSeat(isSelected: isSelected, isHovering: isHovering, radius: 6, barInset: 3)
        .padding(.horizontal, Theme.Space.xs)
    }
}

private struct SidebarMenuRow<Items: View>: View {
    var label: String
    var symbol: String
    var help: String
    @ViewBuilder var items: () -> Items

    @State private var isHovering = false

    var body: some View {
        Menu {
            items()
        } label: {
            SidebarRowLabel(label: label, symbol: symbol, isSelected: false, isHovering: isHovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

#if os(macOS)
private enum RowMetrics {
    static let mark: CGFloat = 26
    static let title: CGFloat = 13
    static let meta: CGFloat = 11
    static let lineGap: CGFloat = 2
    static let rowPadding: CGFloat = 6
    static let dot: CGFloat = 7
}

private struct StateBadge: View {
    let state: SessionState
    var since: Date?
    var statusLabel: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var tint: Color {
        switch state {
        case .working: return Theme.stateWorking
        case .starting: return Theme.stateWorking.opacity(0.5)
        case .needsAttention: return Theme.warning
        case .stopped, .failed: return Theme.danger
        case .done: return Theme.stateIdle
        case .idle, .none: return Theme.stateIdle
        }
    }

    private var label: String {
        if let statusLabel { return statusLabel }
        switch state {
        case .none: return L10n.text("apple.rootview.no_sessions.f857df8f")
        case .working: return L10n.text("common.working")
        case .starting: return L10n.text("apple.rootview.starting.aeed4d26")
        case .idle: return L10n.text("common.idle")
        case .needsAttention: return L10n.text("apple.rootview.needs_attention.c1ebc781")
        case .stopped: return L10n.text("apple.rootview.stopped.1a4f630a")
        case .done: return L10n.text("common.done")
        case .failed: return L10n.text("common.failed")
        }
    }

    private var labelStyle: AnyShapeStyle {
        switch state {
        case .working: return AnyShapeStyle(Theme.stateWorking)
        case .needsAttention: return AnyShapeStyle(Theme.warning)
        case .failed: return AnyShapeStyle(Theme.danger)
        default: return AnyShapeStyle(.tertiary)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if state != .none {
                Circle()
                    .fill(tint)
                    .frame(width: RowMetrics.dot, height: RowMetrics.dot)
                    .animation(pulsing ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : nil) {
                        $0.opacity(pulsing ? 0.45 : 1)
                    }
                    .onAppear { startPulse() }
                    .onChange(of: state) { _, _ in startPulse() }
            }
            Text(label)
                .font(Theme.fit(RowMetrics.meta))
                .foregroundStyle(labelStyle)
                .lineLimit(1)
            if state == .idle, let since {
                Text("·").font(Theme.fit(RowMetrics.meta)).foregroundStyle(.quaternary)
                // One shared tick, not a live time source per row. SwiftUI
                // does keep `Text(_, style: .relative)` current on its own,
                // and the price is a full window layout pass every frame for
                // as long as one is on screen. See `RelativeClock`.
                RelativeTimeText(date: since, unitsStyle: .short)
                    .font(Theme.numeric(RowMetrics.meta))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func startPulse() {
        guard state == .working, !reduceMotion else {
            pulsing = false
            return
        }
        pulsing = true
    }
}

private enum WorkspaceDrag {
    static let prefix = "tokenstat.workspace:"
    static let end = "__end__"

    static func payload(_ id: String) -> String { prefix + id }

    static func id(from payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        return String(payload.dropFirst(prefix.count))
    }
}

private struct WorkspaceReorder: ViewModifier {
    let id: String
    var canDrag: Bool = true
    let enabled: Bool
    let onDrop: (String) -> Void
    let onTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if canDrag {
            drop(on: content)
                .draggable(WorkspaceDrag.payload(id)) {
                    Text((id as NSString).lastPathComponent)
                        .font(Theme.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                }
        } else {
            drop(on: content)
        }
    }

    private func drop(on content: Content) -> some View {
        content.dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let dragged = WorkspaceDrag.id(from: payload),
                  dragged != id else { return false }
            onDrop(dragged)
            return true
        } isTargeted: { on in
            onTargeted(on)
        }
    }
}

private struct WorkspaceRow: View {
    let folder: WorkspaceFolder
    let isSelected: Bool
    let isCurrent: Bool
    let summary: WorkspaceSummary?
    let activeTerminals: Int
    var isStale = false
    var isShared = false
    var share: (() -> Void)? = nil
    let rename: (String) async throws -> Void
    let remove: () -> Void
    let reveal: () -> Void
    let newChat: () -> Void
    let actions: () -> [NativeMenuItem]
    let action: () -> Void

    @State private var isHovering = false
    @State private var controlsHovered = false
    @State private var composeHovered = false
    @State private var renaming = false

    private var label: String {
        folder.isRemote
            ? "\(folder.machineLabel ?? L10n.text("apple.rootview.remote.ffa98e02")) / \(folder.name)"
            : folder.name
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: folder.isGeneral ? folder.symbol : folder.isRemote ? "network" : (isShared ? "folder.badge.person.crop" : (folder.exists ? "folder" : "questionmark.folder")))
                        .symbolVariant(isCurrent ? .fill : .none)
                        .font(Theme.fit(13, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.controlGlyph)
                        .frame(width: 18)
                    Text(label)
                        .font(Theme.fit(RowMetrics.title, weight: isCurrent ? .semibold : .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if isStale {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(Theme.warning)
                            .help("Offline · saved folders")
                            .accessibilityLabel("Offline · saved folders")
                    }
                    Spacer(minLength: Theme.Space.xs)
                    changeCounts.opacity(isHovering ? 0 : 1)
                        .frame(minWidth: share == nil ? 52 : 80, alignment: .trailing)
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(maxWidth: .infinity)
                .frame(height: DisplayFit.dp(Theme.Control.sidebarRow))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                if let share {
                    Button(action: share) {
                        Image(systemName: (isShared ? ActionIcon.team : ActionIcon.connect).symbol)
                            .font(Theme.fit(12, weight: .medium))
                            .foregroundStyle(isShared ? Theme.accent : Theme.controlGlyph)
                            .frame(width: 24, height: 24).contentShape(.rect)
                    }.buttonStyle(.plain)
                        .help(L10n.text(isShared ? "common.teams.open_shared_project" : "common.teams.share_project"))
                        .accessibilityLabel(L10n.text(isShared ? "common.teams.open_shared_project" : "common.teams.share_project"))
                        .accessibilityIdentifier("project.share.\(folder.id)")
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                        .accessibilityHidden(!isHovering)
                }
                SidebarRowActions(name: folder.name, visible: isHovering, canDelete: !isStale && !folder.isGeneral,
                                  deleteTitle: L10n.text("apple.rootview.remove_project.704e7388"), delete: remove,
                                  hover: { _ in }, actions: { menu })
                Button(action: newChat) {
                    Image(systemName: "square.and.pencil")
                        .font(Theme.fit(12, weight: .medium))
                        .foregroundStyle(composeHovered ? Theme.accent : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(composeHovered ? Theme.accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isStale)
                .help(L10n.text("apple.rootview.new_chat_in_0.2436f7d3", "\(folder.name)"))
                .accessibilityLabel(L10n.text("apple.rootview.new_chat_in_0.2436f7d3", "\(folder.name)"))
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
                .onHover { composeHovered = $0 }
            }
            .contentShape(.rect)
            .onHover { controlsHovered = $0 }
            .padding(.trailing, Theme.Space.s)
        }
        .background(background)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .sidebarContextMenu(items: { menu })
        .sidebarHoverCard(hovering: isHovering, enabled: !renaming, suppressOpening: controlsHovered) {
            SidebarDetailCard(title: folder.name, subtitle: L10n.text("apple.rootview.project.98595978"), symbol: "folder",
                              path: folder.path, fields: detailFields, git: folder.git) {
                if !folder.isRemote {
                    Button(L10n.text("apple.rootview.open_in_finder.91fd498d"), .reveal, action: reveal)
                        .buttonStyle(AccentButtonStyle())
                }
            }
        }
        .sheet(isPresented: $renaming) {
            SidebarRenameSheet(title: L10n.text("apple.rootview.rename_project.2a0478ee"), currentName: folder.name, save: rename)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label). \(folder.subtitle ?? L10n.text("apple.rootview.no_branch.db114adc"))")
        .accessibilityActions {
            if let share {
                Button(L10n.text(isShared ? "common.teams.open_shared_project" : "common.teams.share_project"),
                       isShared ? ActionIcon.team : ActionIcon.connect, action: share)
            }
        }
    }

    private var menu: [NativeMenuItem] {
        var items = actions()
        if !isStale && !folder.isGeneral {
            items.insert(.init(L10n.text("apple.rootview.rename.6fa62b3d"), icon: .edit) { renaming = true }, at: 0)
        }
        return items
    }

    private var detailFields: [SidebarDetailField] {
        var fields = [
            SidebarDetailField(title: L10n.text("apple.rootview.computer.76ed42d2"), value: folder.sidebarComputer, symbol: "laptopcomputer"),
            SidebarDetailField(title: L10n.text("common.chats"), value: summary?.chats.map { $0.formatted() } ?? "Not loaded yet", symbol: "bubble.left.and.bubble.right", numeric: true),
            SidebarDetailField(title: L10n.text("apple.rootview.active_terminals.f3f30a21"), value: (summary?.sessions ?? activeTerminals).formatted(), symbol: "terminal", numeric: true),
        ]
        if folder.git?.isRepo != true {
            fields.append(.init(title: L10n.text("apple.rootview.git.b949c922"), value: folder.exists ? "Not a repository" : "Folder missing", symbol: "questionmark.folder"))
        }
        return fields
    }

    @ViewBuilder
    private var changeCounts: some View {
        let font = Theme.numeric(11)
        if let git = folder.git, git.isRepo {
            HStack(spacing: 4) {
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
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var background: some View {
        SidebarRowSeat(isSelected: isSelected, isHovering: isHovering)
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 1)
    }
}

private struct SidebarGroupHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    let isExpanded: Bool?
    let toggle: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.xs) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                HStack(spacing: Theme.Space.xs) { trailing }
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                heading.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Theme.Space.xs) {
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.xs)
    }

    @ViewBuilder private var heading: some View {
        if let isExpanded {
            Button(action: toggle) {
                header(chevron: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(isExpanded ? L10n.text("apple.rootview.collapse_0.61eb8723", "\(title)") : L10n.text("apple.rootview.expand_0.e1580a27", "\(title)"))
        } else {
            header(chevron: nil)
        }
    }

    private func header(chevron: String?) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if let chevron {
                Image(systemName: chevron)
                    .font(Theme.font(8, weight: .semibold))
                    .foregroundStyle(isHovering ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 8)
            }
            SectionLabel(text: title, count: count)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

extension SidebarGroupHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, isExpanded: Bool?, toggle: @escaping () -> Void) {
        self.init(title: title, count: count, isExpanded: isExpanded, toggle: toggle) {
            EmptyView()
        }
    }
}

private struct SidebarHeaderIconButton: View {
    let systemImage: String
    let help: String
    var isOn: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent)
                                 : (isHovering ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary)))
                .frame(width: Theme.Control.sidebarIcon, height: Theme.Control.sidebarIcon)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? Theme.accent.opacity(0.14) : (isHovering ? Theme.rowHighlight : .clear))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct SidebarViewSwitch: View {
    let display: SidebarProjectsDisplay
    let select: (SidebarProjectsDisplay) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.byRepository, symbol: ActionIcon.reveal.symbol,
                    help: L10n.text("common.sidebar.view_by_repository"))
            segment(.byChat, symbol: ActionIcon.comment.symbol,
                    help: L10n.text("common.sidebar.view_by_chat"))
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.rowHighlight.opacity(0.5))
        )
    }

    private func segment(_ value: SidebarProjectsDisplay, symbol: String, help: String) -> some View {
        let on = display == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { select(value) }
        } label: {
            Image(systemName: symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                .frame(width: Theme.Control.sidebarIcon + 4, height: Theme.Control.sidebarIcon - 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? Theme.rowSelectedNested : .clear)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct SidebarFilterField: View {
    @Binding var text: String
    let prompt: String
    let close: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: ActionIcon.filter.symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.fit(13))
                .focused($focused)
                .onExitCommand(perform: close)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.font(13))
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.Control.sidebarIcon, height: Theme.Control.sidebarIcon)
                    .contentShape(.rect)
            }
            .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
            .help(L10n.text("apple.sshlibraryview.clear_search.3b7ea517"))
            .accessibilityLabel(L10n.text("apple.sshlibraryview.clear_search.3b7ea517"))
        }
        .padding(.leading, Theme.Space.s + 2)
        .padding(.trailing, 2)
        .frame(height: DisplayFit.dp(Theme.Control.sidebarRow))
        .background(Theme.rowHighlight.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear { focused = true }
    }
}

private struct SidebarShowMoreRow: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: ActionIcon.more.symbol)
                    .font(Theme.font(11, weight: .semibold))
                    .frame(width: DisplayFit.dp(16))
                Text(title)
                    .font(Theme.fit(13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, ChatSidebarConversationRow.markInset)
            .frame(maxWidth: .infinity)
            .frame(height: DisplayFit.dp(Theme.Control.sidebarRow))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            SidebarRowSeat(isSelected: false, isHovering: isHovering, hoverOpacity: 0.45, barInset: nil)
                .padding(.horizontal, Theme.Space.xs)
        )
        .onHover { isHovering = $0 }
    }
}

private struct SidebarChatDayHeader: View {
    let title: String
    let isWorking: Bool
    let isCollapsed: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                if isWorking {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(Theme.fit(12, weight: .medium))
                    .foregroundStyle(isWorking ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                Image(systemName: "chevron.down")
                    .font(Theme.font(9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .opacity(isHovering || isCollapsed ? 1 : 0)
                    .animation(Motion.morph, value: isCollapsed)
                    .animation(Motion.hover, value: isHovering)
                Spacer(minLength: 0)
            }
            .padding(.leading, ChatSidebarConversationRow.markInset)
            .padding(.trailing, Theme.Space.m)
            .frame(minHeight: DisplayFit.dp(24), alignment: .bottom)
            .padding(.top, Theme.Space.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCollapsed
              ? L10n.text("apple.rootview.expand_0.e1580a27", title)
              : L10n.text("apple.rootview.collapse_0.61eb8723", title))
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

extension ChatSidebarConversationRow: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.conversation == rhs.conversation && lhs.folder == rhs.folder
                && lhs.draft == rhs.draft && lhs.runningSince == rhs.runningSince
                && lhs.isSelected == rhs.isSelected && lhs.caption == rhs.caption
                && lhs.folderIsOpen == rhs.folderIsOpen
        }
    }
}

private struct ChatSidebarConversationRow: View {
    static let markInset: CGFloat = Theme.Space.m + 1
    static var titleInset: CGFloat { markInset + DisplayFit.dp(16) + Theme.Space.s }

    let conversation: ChatConversation
    let folder: WorkspaceFolder
    let rename: (String) async throws -> Void
    let fork: () async throws -> Void
    let draft: WorkReference?
    let runningSince: Date?
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void
    let openPull: (ChatPull) -> Void
    let warmPreview: () async -> Void
    var caption: String? = nil
    var folderIsOpen = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var confirmsRemoval = false
    @State private var showingDetails = false
    @State private var renaming = false
    @State private var copying = false
    @State private var actionError: String?


    var body: some View {
        #if DEBUG && os(macOS)
        let _ = DebugUIHooks.printsChanges ? Self._printChanges() : ()
        #endif
        ZStack(alignment: .trailing) {
            Button {
                showingDetails = false
                select()
            } label: {
                HStack(spacing: Theme.Space.s) {
                    HarnessMark(id: conversation.backend, size: DisplayFit.dp(16))
                    Text(conversation.title.isEmpty ? L10n.text("apple.rootview.untitled_conversation.31d248c4") : conversation.title)
                        .font(Theme.fit(13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Theme.controlGlyph)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !conversation.pulls.isEmpty {
                        SidebarChatPullMark.label(conversation.pulls)
                            .hidden()
                            .anchorPreference(key: SidebarPullMarkSeat.self, value: .bounds) { $0 }
                    }
                    ChatDraftMark(reference: draft)
                    Spacer(minLength: 0)

                    trailingState
                        .opacity(isHovering ? 0 : 1)
                        .frame(minWidth: Theme.Control.sidebarIcon, alignment: .trailing)
                        .padding(.leading, Theme.Space.s)
                }
                .padding(.leading, Self.markInset)
                .padding(.trailing, Theme.Space.s + 2 + Theme.Control.sidebarIcon + 4)
                .frame(maxWidth: .infinity)
                .frame(height: DisplayFit.dp(32))
                .contentShape(.rect)
            }
            .buttonStyle(ControlFeedbackStyle(highlights: false, pressScale: 0.98))
            .accessibilityLabel(accessibilityTitle)
            HStack(spacing: 4) {
                SidebarRowActions(name: conversation.title, visible: isHovering,
                                  canDelete: conversation.teamShare == nil && !conversation.running && !copying,
                                  deleteTitle: L10n.text("apple.rootview.delete_chat.93291d9c"), delete: { confirmsRemoval = true },
                                  hover: { _ in }, actions: { menu })
                SidebarChatDetailButton(conversation: conversation, folder: folder, isPresented: $showingDetails,
                                        isRevealed: isHovering || isSelected)
                    .disabled(renaming || confirmsRemoval || copying || actionError != nil)
            }
            .padding(.trailing, Theme.Space.s + 2)
        }
        .overlayPreferenceValue(SidebarPullMarkSeat.self) { seat in
            GeometryReader { row in
                if let seat {
                    let frame = row[seat]
                    SidebarChatPullMark(pulls: conversation.pulls, open: openPull)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .background(
            SidebarRowSeat(isSelected: isSelected, isHovering: isHovering,
                           selectedFill: Theme.rowSelectedNested, hoverOpacity: 0.45, barInset: nil)
                .padding(.horizontal, Theme.Space.xs)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .task(id: isHovering && !isSelected) {
            guard isHovering, !isSelected else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            await warmPreview()
        }
        .sidebarContextMenu(items: { menu })
        .onChange(of: isSelected) { _, _ in showingDetails = false }
        .onChange(of: SidebarMenuTracking.shared.active) { _, active in
            if active { showingDetails = false }
        }
        .sheet(isPresented: $renaming) {
            SidebarRenameSheet(title: L10n.text("apple.rootview.rename_chat.26076241"), currentName: conversation.title, save: rename)
        }
        .alert(L10n.text("apple.rootview.couldn_t_fork_this_chat.3aace6d2"), isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button(L10n.text("apple.rootview.ok.565339bc"), role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .confirmationDialog(
            L10n.text("apple.rootview.delete_this_chat.848dad9b"),
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.rootview.delete_chat.93291d9c"), role: .destructive, action: remove)
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.rootview.this_permanently_deletes_the_transcript.470ca3e0"))
        }
    }
    private var accessibilityTitle: String {
        let title = conversation.title.isEmpty ? L10n.text("apple.rootview.untitled_conversation.31d248c4") : conversation.title
        guard let caption else { return title }
        return "\(title), \(caption)"
    }

    private var menu: [NativeMenuItem] {
        var items = [NativeMenuItem(L10n.text("apple.rootview.rename.6fa62b3d"), icon: .edit, isEnabled: conversation.teamShare == nil) { renaming = true }]
        items += SidebarPinAction.items(reference: draft, name: conversation.title, folderName: folder.name)
        items.append(.init(copying ? L10n.text("apple.rootview.forking.b24686d8") : L10n.text("apple.rootview.fork_chat.dfbcbb35"), icon: .copy, isEnabled: conversation.teamShare == nil && !conversation.running && !copying) {
            guard !copying else { return }
            copying = true
            Task {
                defer { copying = false }
                do { try await fork() }
                catch { actionError = error.localizedDescription }
            }
        })
        items.append(.separator)
        items.append(.init(L10n.text("apple.rootview.delete_chat.f618c627"), icon: .delete, isEnabled: conversation.teamShare == nil && !conversation.running && !copying,
                           destructive: true) { confirmsRemoval = true })
        return items
    }

}

extension ChatSidebarConversationRow {
    @ViewBuilder
    fileprivate var trailingState: some View {
        if conversation.running {
            HStack(spacing: 4) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                if let since = runningSince {
                    TurnElapsedText(since: since)
                } else {
                    Text(L10n.text("common.working"))
                }
            }
            .font(Theme.numeric(11))
            .foregroundStyle(Theme.accent)
            .fixedSize()
            .accessibilityLabel(L10n.text("common.working"))
        } else if let caption {
            Text(caption)
                .font(Theme.fit(11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: DisplayFit.dp(72), alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(CompactAge.text(ms: conversation.lastMessageAtMs ?? conversation.updatedAtMs))
                .font(Theme.numeric(11))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

private struct ActiveWorkflowRow: View {
    let run: WorkflowRunRecord
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_workflow", tint: Theme.accent, size: DisplayFit.dp(RowMetrics.mark))
                VStack(alignment: .leading, spacing: RowMetrics.lineGap) {
                    Text(run.name)
                        .font(Theme.fit(RowMetrics.title, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(L10n.text("apple.rootview.0_steps.5cd7f90f", "\(run.steps.count)"))
                        .font(Theme.numeric(RowMetrics.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    StateBadge(state: run.isWaiting ? .needsAttention : .working)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, RowMetrics.rowPadding)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L10n.text("apple.rootview.open_this_running_workflow.5320e2a2"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.name). \(run.endedLabel)")
    }

    private var background: some View {
        SidebarRowSeat(isSelected: isSelected, isHovering: isHovering)
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 1)
    }
}

private struct ActiveAutomationRow: View {
    let job: Automation
    let backendLabel: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_automation", tint: Theme.accent, size: DisplayFit.dp(RowMetrics.mark))
                VStack(alignment: .leading, spacing: RowMetrics.lineGap) {
                    Text(job.name)
                        .font(Theme.fit(RowMetrics.title, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(backendLabel)
                        .font(Theme.numeric(RowMetrics.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    StateBadge(state: .working)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, RowMetrics.rowPadding)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L10n.text("apple.rootview.open_this_running_job.562692ab"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.rootview.0_1_working.6e868daa", "\(job.name)", "\(backendLabel)"))
    }

    private var background: some View {
        SidebarRowSeat(isSelected: isSelected, isHovering: isHovering)
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 1)
    }
}

private struct ActiveSessionRow: View {
    let session: TerminalSession
    let folder: WorkspaceFolder
    let duplicate: () -> Void
    let isSelected: Bool
    let close: () -> Void
    let action: () -> Void

    @State private var isHovering = false
    @State private var showingDetails = false
    @State private var renaming = false


    private var title: String {
        if let name = session.customName { return name }
        if let harnessID = session.harnessID { return harnessName(harnessID) }
        return (session.command as NSString).lastPathComponent
    }

    private var dynamicTitle: String? {
        guard let reported = session.title?.trimmingCharacters(in: .whitespaces),
              !reported.isEmpty,
              !reported.localizedCaseInsensitiveContains(title),
              !title.localizedCaseInsensitiveContains(reported)
        else { return nil }
        return reported
    }

    private var stats: String? {
        if let meter = session.meter {
            let money = Money(
                micros: meter.costMicros ?? 0,
                estimated: meter.estimated,
                complete: meter.complete
            ).formatted
            let tokens = meter.tokens == 0 ? "0k" : formatTokens(meter.tokens)
            return "\(contextText) · \(money) · \(tokens)"
        }
        return resourceStats
    }

    private var contextText: String {
        guard let meter = session.meter, let used = meter.contextUsed else {
            return "— ctx"
        }
        guard let window = meter.contextWindow, window > 0 else {
            return L10n.text("apple.rootview.0_ctx.a68da93d", "\(formatTokens(used))")
        }
        let pct = Int((Double(used) / Double(window) * 100).rounded())
        return L10n.text("apple.rootview.0_1_ctx.a6e7a82e", "\(meter.contextEstimated ? "~" : "")", "\(pct)")
    }

    private var resourceStats: String? {
        var parts: [String] = []
        if let cpu = session.cpuPercent {
            parts.append(L10n.text("apple.rootview.cpu_0.bc621b54", "\(Int(cpu.rounded()))"))
        }
        if let memory = session.memoryMb, memory >= 1 {
            parts.append(
                memory >= 1000
                    ? String(format: "%.1f GB", memory / 1024)
                    : "\(Int(memory.rounded())) MB"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines = [session.cwd]
        if let stats { lines.append(stats) }
        if session.meter != nil, let resources = resourceStats {
            lines.append(resources)
        }
        if session.meter?.costMicros != nil {
            lines.append(
                session.meter?.isPlan == true
                    ? L10n.text("apple.rootview.covered_by_your_plan_api_list_price_not_an.ed0c7f17")
                    : L10n.text("apple.rootview.api_list_price_not_an_extra_bill.a12d94fd")
            )
        }
        if session.meter?.contextEstimated == true {
            lines.append(L10n.text("apple.rootview.context_window_estimated_from_related_mode.9d7879e3"))
        }
        return lines.joined(separator: "\n")
    }

    private var spokenLabel: String {
        var parts = [title]
        if let stats { parts.append(stats) }
        if let meter = session.meter,
           let used = meter.contextUsed,
           let window = meter.contextWindow,
           window > 0
        {
            let pct = Int((Double(used) / Double(window) * 100).rounded())
            parts.append(L10n.text("apple.rootview.context_0_percent.abe03309", "\(pct)"))
        }
        parts.append(session.state.label)
        return parts.joined(separator: ". ")
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                showingDetails = false
                action()
            } label: {
                HStack(spacing: Theme.Space.s) {
                    leadingMark
                    Text(dynamicTitle.map { "\(title) · \($0)" } ?? title)
                        .font(Theme.fit(13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Theme.controlGlyph)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    StateBadge(state: session.state, since: session.lastOutputAt, statusLabel: session.statusLabel)
                        .opacity(isHovering ? 0 : 1)
                        .frame(minWidth: 26, alignment: .trailing)
                }
                .padding(.leading, ChatSidebarConversationRow.markInset)
                .padding(.trailing, Theme.Space.s + 2 + Theme.Control.sidebarIcon + 4)
                .frame(maxWidth: .infinity)
                .frame(height: DisplayFit.dp(Theme.Control.sidebarRow))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                SidebarRowActions(name: title, visible: isHovering,
                                  deleteTitle: session.alive ? L10n.text("apple.rootview.stop_and_close.52b40c33") : L10n.text("apple.rootview.close_terminal.7d02fb04"),
                                  delete: close, hover: { _ in }, actions: { menu })
                SidebarDetailButton(title: title, isPresented: $showingDetails, isRevealed: isHovering || isSelected) {
                    SidebarTerminalDetailCard(session: session, folder: folder)
                }
                .disabled(renaming)
            }
            .padding(.trailing, Theme.Space.s + 2)
        }
        .background(background)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .sidebarContextMenu(items: { menu })
        .onChange(of: isSelected) { _, _ in showingDetails = false }
        .onChange(of: session.workReference) { _, _ in showingDetails = false }
        .onChange(of: SidebarMenuTracking.shared.active) { _, active in
            if active { showingDetails = false }
        }
        .sheet(isPresented: $renaming) {
            SidebarRenameSheet(title: L10n.text("apple.rootview.rename_terminal.68e0c2a6"), currentName: title) { name in
                SidebarTerminalNames.shared.rename(session.workReference, to: name, folderName: folder.name)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenLabel)
    }

    private var menu: [NativeMenuItem] {
        var items = [NativeMenuItem(L10n.text("apple.rootview.rename.6fa62b3d"), icon: .edit, isEnabled: session.workReference != nil) { renaming = true }]
        items += SidebarPinAction.items(reference: session.workReference, name: title, folderName: folder.name)
        items.append(.init(L10n.text("apple.rootview.duplicate_into_new_shell.67042025"), icon: .copy, isEnabled: !session.isPending, action: duplicate))
        items.append(.separator)
        items.append(.init(session.alive ? L10n.text("apple.rootview.stop_and_close.9712e7bb") : L10n.text("common.close"), icon: .delete,
                           destructive: true, action: close))
        return items
    }

    @ViewBuilder
    private var leadingMark: some View {
        if let harnessID = session.harnessID {
            HarnessMark(id: harnessID, size: DisplayFit.dp(16))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "apple.terminal.fill")
                        .font(Theme.font(DisplayFit.dp(7), weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(1)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
        } else {
            Image(systemName: "terminal")
                .font(Theme.fit(11, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.8))
                .frame(width: DisplayFit.dp(16), height: DisplayFit.dp(16))
        }
    }

    private var background: some View {
        SidebarRowSeat(isSelected: isSelected, isHovering: isHovering,
                       selectedFill: Theme.rowSelectedNested, hoverOpacity: 0.45, barInset: nil)
            .padding(.horizontal, Theme.Space.xs)
    }
}
#endif

#endif

private struct PendingPullOpen: Identifiable {
    let pull: ChatPull
    let folder: WorkspaceFolder
    var id: String { pull.id }
}
