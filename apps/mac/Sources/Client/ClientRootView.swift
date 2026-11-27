// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
import StoreKit
import UIKit
#endif

// The client is iOS and iPadOS only. The Mac has `RootView`, and these
// screens lean on toolbar placements and a tab bar that macOS does not
// have, so compiling them there would only break the desktop build.
#if !os(macOS)

/// The root of the iPhone and iPad client.
///
/// Not a narrow `RootView`. The Mac app is a workbench with two sidebars, a
/// terminal stack and a git pane, and a phone-sized copy of it would be the
/// wrong app rather than a smaller one. This root answers the two questions
/// someone opens a phone for, which `docs/ios-client-ui.md` states as: what did
/// I spend, and how much of my plan is left.
///
/// The chrome is the system's own. A `TabView` on iOS 26 draws the floating
/// glass bar, a `.toolbar` draws the glass top bar, and both keep their
/// behaviour under Reduce Transparency and Reduce Motion without this file
/// knowing about either. On iOS 17 and 18 the same tabs sit on the system
/// bar of that year: no glass, no minimise-on-scroll. Custom glass is for
/// the places no system control exists, and there are deliberately very few.
struct ClientRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var launch = LaunchState()
    @State private var account = AccountModel()
    @State private var teams = TeamStore(api: .live)
    @State private var webAuth = ClientWebAuth()
    @State private var connectivity = ConnectivityModel()
    @State private var connection = ConnectionModel()
    @State private var input = PointerKeyboardModel()
    @State private var navigation = ClientNavigationModel()
    @State private var tabCustomization = ClientTabCustomization.shared
    @State private var editors = ClientEditorStore(
        write: ClientRemote.writeFile,
        read: { peer, workspace, path in
            try await ClientRemote.readFile(peer: peer, workspace: workspace, path: path).content
        },
        sessionID: { WorkSessionContext.shared.scope.map(AnyHashable.init) }
    )
    @State private var showAccount = false
    @State private var store = ClientStore()
    @State private var notificationOpen = NotificationOpen.shared
    @State private var ecosystemNavigation = EcosystemNavigation.shared
    @State private var savedAccess = SavedWorkAccess.shared

    @State private var introProgress = ClientIntroProgress()

    @ViewBuilder
    private var signedOut: some View {
        ClientLoginView()
            .transition(.opacity)
            .sheet(isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            )) {
                ClientOnboarding(flow: introProgress)
                    .clientIntroSheetSizing()
            }
    }

    @AppStorage("client.hasOnboarded") private var hasOnboarded = false
    @State private var showingSetupTour = false
    @State private var showingHandleOffer = false

    private var canOfferHandle: Bool {
        scenePhase == .active && account.signedIn && navigation.destination == .home
            && !showingSetupTour && !showAccount && !store.showPaywall
            && !navigation.showWorkSearch && navigation.presentedChat == nil
            && !navigation.showingNewChat
            && navigation.presentedTaskBoard == nil && savedAccess.reader == nil
    }

    private var canRequestReview: Bool {
        scenePhase == .active && account.signedIn && navigation.destination == .home
            && !showingSetupTour && !showingHandleOffer && !showAccount && !store.showPaywall
            && !navigation.showWorkSearch && navigation.presentedChat == nil
            && navigation.presentedTaskBoard == nil && savedAccess.reader == nil
    }

    @AppStorage("client.layoutMode") private var layoutPreference = ClientLayoutPreference.automatic.rawValue

    @State private var windowWidth: CGFloat = 0

    @State private var sessionModels = ClientSessionModels()

    private func prewarmSavedHost() {
        guard account.signedIn, let signed = account.account,
              let scope = WorkSessionContext.shared.scope else { return }
        let workspaces = sessionModels.models(for: scope).workspaces
        Task {
            await BridgeLaunch.wait()
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
            await workspaces.refresh(account: signed)
            await workspaces.autoConnectLastHost()
        }
    }

    @State private var layoutHandoff: WorkMobileRoute?
    @State private var layoutHandoffIntent: UInt64 = 0

    private var layout: ClientLayoutMode {
        ClientLayout.mode(
            preference: ClientLayoutPreference(rawValue: layoutPreference) ?? .automatic,
            hasDesktopInput: input.hasDesktopInput,
            sizeClass: sizeClass,
            verticalSizeClass: verticalSizeClass,
            width: windowWidth
        )
    }

    private func reopenConversation(_ route: WorkMobileRoute) -> Bool {
        guard let reference = route.reference, reference.kind == .conversation,
              let chatID = reference.itemID, !chatID.isEmpty else { return false }
        let workspaces = sessionModels.models(for: route.scope).workspaces
        guard workspaces.connectedKey == reference.hostIdentity,
              let folder = workspaces.folders.first(where: {
            (ClientRemote.rawWorkspaceID(of: $0) ?? $0.id) == reference.workspaceID
        }) else { return false }
        if layout == .sidebar {
            navigation.restoredRoute = nil
            navigation.openChat(folderID: folder.id, chatID: chatID, restoringLayout: true)
        } else {
            let hostName = workspaces.hosts.first { $0.peerKey == reference.hostIdentity }?.name ?? ""
            navigation.restoredRoute = nil
            navigation.workspacesPath = []
            navigation.pushFolder(peerKey: reference.hostIdentity, hostName: hostName,
                                  folder: folder, section: .chat)
            navigation.requestedChat = reference
        }
        return true
    }

    private var rootSurface: some View {
        Group {
            if !launch.hostReady || account.authPending {
                LaunchSplashView()
                    .transition(.opacity)
            } else if account.authNeedsRetry {
                ClientAuthRetryView(
                    message: account.authCheckError,
                    isLoading: account.isLoading,
                    onSavedWork: savedAccess.offeredOwner.map { owner in
                        { _ = savedAccess.beginReading(owner) }
                    }
                ) {
                    Task { await account.load() }
                }
                .transition(.opacity)
            } else if !account.signedIn {
                signedOut
            } else if layout == .sidebar {
                ClientSidebarRoot(
                    showAccount: $showAccount,
                    workspaces: sessionModels.models(for: WorkSessionContext.shared.scope).workspaces
                )
                    .sessionScreens(sessionModels.models(for: WorkSessionContext.shared.scope))
                    .id(WorkSessionContext.shared.scope)
                    .id(navigation.stackGeneration)
                    .transition(.opacity)
            } else {
                tabs
                    .sessionScreens(sessionModels.models(for: WorkSessionContext.shared.scope))
                    .id(WorkSessionContext.shared.scope)
                    .id(navigation.stackGeneration)
                    .transition(.opacity)
                    .onChange(of: tabCustomization.visibleTabs) { _, visible in
                        if !visible.contains(navigation.destination) {
                            navigation.destination = visible.first ?? .home
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: account.signedIn)
        .animation(.easeInOut(duration: 0.28), value: account.authChecked)
        .animation(.easeInOut(duration: 0.28), value: account.authNeedsRetry)
        .animation(.easeInOut(duration: 0.28), value: layout)
        .tint(Theme.accent)
        .clientPointerProbe(input)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { windowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in windowWidth = width }
            }
            ScreenSizeReporter()
            ClientWebAuthAnchor(auth: webAuth)
        }
    }

    private var rootLifecycle: some View {
        rootSurface
        .task {
            SetupTourPreferences.noteLaunch()
            ClientReviewPrompt.noteLaunch()
            connectivity.start()
            input.start()
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
                    message: L10n.text("apple.clientrootview.this_device_is_offline.84b7cf97")
                )
            }
            account.signInPresenter = { webAuth.start($0) }
            account.signInDismisser = { webAuth.cancel() }
            store.currentAccount = { account.account }
            store.onAccountChange = { updated in
                account.account = updated
                NotificationCenter.default.post(name: .tokenstatEntitlementDidChange, object: nil)
                Task { _ = try? await Bridge.reconsiderPlan() }
            }
            store.start()
            await launch.prepare()
            await ClientDeviceName.publish()
            await account.load()
            if let signed = account.account {
                await store.finishPendingIntent(with: signed)
            }
        }
        .onChange(of: navigation.currentRoute) { _, _ in navigation.saveRoute() }
        .onChange(of: layout) { _, newLayout in
            navigation.sidebarLayoutActive = newLayout == .sidebar
            navigation.layoutGeneration &+= 1
            navigation.stackGeneration &+= 1
            if navigation.pushedChat != nil, navigation.chatHandoff.reader == nil,
               navigation.pullHandoff == nil {
                layoutHandoff = nil
                return
            }
            if let route = navigation.currentRoute, route.reference != nil,
               navigation.presentedChat == nil,
               sessionModels.models(for: route.scope).workspaces.activeTerminal == nil {
                if route.reference?.kind != .conversation {
                    navigation.restoreLayout { navigation.restoredRoute = route }
                }
                _ = navigation.chatHandoff.begin(route: route)
                navigation.restoreLayout { navigation.pushedChat = nil }
                layoutHandoffIntent = navigation.chatHandoff.intent
                layoutHandoff = route
            }
        }
        .onChange(of: ClientLayout.hasRoom(horizontal: sizeClass, vertical: verticalSizeClass)) { _, _ in
            navigation.layoutGeneration &+= 1
            if layoutHandoff == nil, let pull = navigation.pullHandoff,
               let route = navigation.currentRoute, route.reference == pull.reference,
               route.section == "pulls", navigation.restoredRoute != route {
                navigation.restoreLayout { navigation.restoredRoute = route }
                layoutHandoffIntent = navigation.chatHandoff.intent
                layoutHandoff = route
            }
        }
        .task(id: navigation.layoutGeneration) {
            let delivery = navigation.chatHandoff.pending
            guard let route = layoutHandoff ?? delivery?.route else { return }
            let intent = delivery?.intent ?? layoutHandoffIntent
            let layoutTicket = navigation.layoutGeneration
            layoutHandoff = nil
            await Task.yield()
            guard !Task.isCancelled, route.scope == WorkSessionContext.shared.scope,
                  intent == navigation.chatHandoff.intent,
                  layoutTicket == navigation.layoutGeneration,
                  navigation.presentedChat == nil,
                  sessionModels.models(for: route.scope).workspaces.activeTerminal == nil else { return }
            if let delivery, !navigation.chatHandoff.isCurrent(delivery, scope: WorkSessionContext.shared.scope) { return }
            let reader = delivery?.reader ?? navigation.chatHandoff.reader
                ?? navigation.restoredChatReader.flatMap { $0.matches(route) ? $0 : nil }
            navigation.restoreLayout {
                if reader?.key.conversation == nil, reopenConversation(route) { return }
                navigation.restoredChatReader = reader?.matches(route) == true ? reader : nil
                if let tab = ClientTab(rawValue: route.tab), tabCustomization.visibleTabs.contains(tab),
                   navigation.destination != tab {
                    navigation.destination = tab
                }
                if navigation.restoredRoute != route { navigation.restoredRoute = route }
            }
        }
        .environment(\.openTeamChat) { share, workspace in
            teams.openSharedChat(id: share, workspace: workspace)
            navigation.destination = .team
        }
        .task(id: teamAccountOwner) {
            await BridgeLaunch.wait()
            guard !Task.isCancelled else { return }
            await teams.bind(to: teamAccountOwner)
            await teams.refreshSelected()
        }
        .task(id: teams.selectionKey) { await teams.refreshSelected() }
        .task(id: TeamAppPresenceKey(owner: teams.owner, active: scenePhase == .active && teams.phase == .ready, supported: teams.capabilities?.supportsAppPresence == true)) {
            await teams.watchAppPresence(active: { UIApplication.shared.applicationState == .active })
        }
        .task(id: WorkSessionContext.shared.generation) {
            let retained = sessionModels.models(for: WorkSessionContext.shared.scope).ssh
            retained.setForeground(scenePhase == .active)
            await retained.watch(tier: account.account?.vaultTierForSsh)
        }
        .onChange(of: account.account?.vaultTierForSsh) { _, tier in
            let retained = sessionModels.models(for: WorkSessionContext.shared.scope).ssh
            Task {
                guard account.account?.vaultTierForSsh == tier else { return }
                await retained.library.ensureLoaded(vaultTier: SSHLibraryModel.paidTier(for: tier))
            }
        }
        .onChange(of: WorkSessionContext.shared.scope, initial: true) { oldScope, newScope in
            if oldScope != nil && oldScope != newScope {
                navigation.reset()
                _ = NotificationOpen.shared.take()
                editors.reset()
            }
            navigation.restoreRoute(visibleTabs: tabCustomization.visibleTabs,
                notificationPending: notificationOpen.request != nil || ecosystemNavigation.hasRequestedNavigation)
            openEcosystemDestination()
            prewarmSavedHost()
        }
        .onChange(of: account.account?.machines) { _, _ in prewarmSavedHost() }
        .onContinueUserActivity("ai.tokenstat.open") { activity in
            if let value = activity.userInfo?["url"] as? String, let url = URL(string: value) { ecosystemNavigation.receive(url) }
        }
        .onOpenURL { url in
            #if DEBUG
            if url.scheme == "tokenstat", url.host == "debug" {
                switch url.path {
                case "/setup": showingSetupTour = true
                default: break
                }
                return
            }
            #endif
            ecosystemNavigation.receive(url)
        }
        .onChange(of: ecosystemNavigation.pending, initial: true) { _, _ in openEcosystemDestination() }
        .onChange(of: account.signedIn) { _, signedIn in
            openEcosystemDestination()
            if !signedIn {
                editors.reset()
                sessionModels.reset()
            }
            guard signedIn, let signed = account.account else { return }
            Task { await store.finishPendingIntent(with: signed) }
            prewarmSavedHost()
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            connection.reset()
            Task { await account.load() }
            Task { await Bridge.nudgeTunnel(reconnect: true) }
            prewarmSavedHost()
        }
        .onChange(of: scenePhase) { _, phase in
            sessionModels.models(for: WorkSessionContext.shared.scope).ssh.setForeground(phase == .active)
            if phase == .active { EcosystemWatchSync.shared.activate() }
            if phase != .active { navigation.saveRoute() }
            guard phase == .active, account.signedIn else { return }
            Task { await Bridge.nudgeTunnelOnForeground() }
            if navigation.destination == .team || teams.phase == .authorization { Task { await teams.reloadAfterChange() } }
        }
        .task(id: scenePhase == .active && account.signedIn) {
            guard scenePhase == .active, account.signedIn else { return }
            while !Task.isCancelled {
                if let scope = WorkSessionContext.shared.scope {
                    sessionModels.models(for: scope).workspaces.revisitRememberedHosts()
                }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

    private var teamAccountOwner: TeamAccountOwner? {
        let context = WorkSessionContext.shared
        guard account.signedIn, let scope = context.scope, scope.kind == .account,
              let session = context.accountSession, !session.isEmpty else { return nil }
        return TeamAccountOwner(scope: scope, generation: context.generation, session: session, personId: account.account?.accountId)
    }

    private var rootPresentations: some View {
        rootLifecycle
        .fullScreenCover(isPresented: Binding(get: { navigation.showingNewChat }, set: { navigation.showingNewChat = $0 }),
                         onDismiss: openPendingNewChatRequest) {
            ClientNewChatScreen()
        }
        .fullScreenCover(item: Binding(
            get: { savedAccess.reader },
            set: { if $0 == nil { savedAccess.endReading() } }
        )) { owner in
            ClientSavedWorkView(owner: owner)
        }
        .sheet(isPresented: Binding(get: { navigation.showWorkSearch }, set: { navigation.showWorkSearch = $0 }),
               onDismiss: openPendingPlace) {
            ClientWorkSearchPresentation()
        }
        .environment(\.openClientAccount, { showAccount = true })
        .sheet(isPresented: $showingSetupTour, onDismiss: { SetupTourPreferences.markSeen() }) {
            SetupTour(signedIn: true, remote: nil, onSignIn: {}, onFinish: { showingSetupTour = false })
        }
        .task(id: "\(account.signedIn)-\(navigation.destination == .home)") {
            guard account.signedIn, navigation.destination == .home else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, navigation.destination == .home,
                  SetupTourPreferences.shouldShow(signedIn: account.signedIn), !showAccount else { return }
            showingSetupTour = true
        }
        .modifier(HandleOffer(model: account, ready: canOfferHandle, showing: $showingHandleOffer))
        .task(id: canRequestReview) {
            guard canRequestReview else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard canRequestReview,
                  ClientReviewPrompt.isDue(machines: account.account?.machines.count ?? 0) else { return }
            ClientReviewPrompt.markAsked()
            requestReview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatOpenSetupTour)) { _ in
            guard account.signedIn else { return }
            if showAccount {
                showAccount = false
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    showingSetupTour = true
                }
            } else {
                showingSetupTour = true
            }
        }
        .sheet(isPresented: $showAccount) {
            ClientAccountSheet(
                offersLayoutChoice: ClientLayout.hasRoom(horizontal: sizeClass, vertical: verticalSizeClass)
            )
        }
        .sheet(isPresented: Binding(
            get: { store.showPaywall },
            set: { store.showPaywall = $0 }
        )) {
            ClientPaywallView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatOpenPaywall)) { _ in
            store.showPaywall = true
        }
        .onChange(of: notificationOpen.request, initial: true) { _, request in
            guard request?.kind == .chat || request?.kind == .session else { return }
            navigation.restoredRoute = nil
            if navigation.destination != .workspaces {
                navigation.destination = .workspaces
            }
        }
        .fullScreenCover(item: Binding(
            get: { navigation.presentedChat },
            set: { navigation.presentedChat = $0 }
        )) { target in
            NavigationStack {
                ClientRecentChatView(
                    peer: target.peer,
                    workspaceID: target.workspaceID,
                    folderName: target.folderName,
                    hostName: target.hostName,
                    chatID: target.chatID,
                    rootChatReference: target.reference
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("common.close")) { navigation.presentedChat = nil }
                    }
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { navigation.presentedTaskBoard },
            set: { navigation.presentedTaskBoard = $0 }
        )) { target in
            NavigationStack {
                ClientTaskBoardDestination(peer: target.peer, hostName: target.hostName)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.text("common.close")) { navigation.presentedTaskBoard = nil }
                        }
                    }
            }
        }
        .modifier(ClientTerminalPresentation(model: sessionModels.models(for: WorkSessionContext.shared.scope).workspaces))
        .modifier(ClientSetupPresentation(session: sessionModels.models(for: WorkSessionContext.shared.scope).setup))
        .modifier(ClientProjectChatActions())
        .modifier(ClientSSHPresentations(workbench: sessionModels.models(for: WorkSessionContext.shared.scope).ssh,
            tier: account.account?.vaultTierForSsh))
    }

    var body: some View {
        rootPresentations
        // **Last in the chain, after every presentation.** A sheet or a cover
        // inherits the environment as it stood where its modifier is written,
        // not as it stands inside the view it is attached to, so an
        // `.environment` above them reaches the screen and nothing presented
        // over it. The two sheets here used to carry their own copies of
        // `account` and `store` for that reason; the cover that a finished-turn
        // notification presents was added later without them, and reading
        // `ClientNavigationModel` out of an environment that did not have it
        // is a trap, not a nil. TestFlight 1.0.0 (88) crashed on every tap of
        // a chat notification. Injecting here covers whatever is presented
        // next as well.
        .environment(account)
        .environment(teams)
        .environment(connectivity)
        .environment(connection)
        .environment(store)
        .environment(input)
        .environment(navigation)
        .environment(\.clientChatHandoffID, navigation.chatHandoff.pending?.id)
        .environment(tabCustomization)
        .environment(editors)
        .environment(sessionModels.models(for: WorkSessionContext.shared.scope).chats)
        .environment(sessionModels.models(for: WorkSessionContext.shared.scope).projectChats)
        .environment(sessionModels.models(for: WorkSessionContext.shared.scope).workspaces)
        .environment(sessionModels.models(for: WorkSessionContext.shared.scope).ssh)
        .environment(sessionModels.models(for: WorkSessionContext.shared.scope).setup)
    }

    private func openEcosystemDestination() {
        guard account.signedIn, let target = ecosystemNavigation.pending else { return }
        ecosystemNavigation.pending = nil
        if target.screen != .account { showAccount = false }
        if target.screen != .search { navigation.showWorkSearch = false; navigation.ecosystemSearchTerm = "" }
        navigation.presentedChat = nil
        navigation.workspacesPath = []
        navigation.folderID = nil
        navigation.restoredRoute = nil
        switch target.screen {
        case .search:
            navigation.ecosystemSearchTerm = target.searchTerm ?? ""
            navigation.showWorkSearch = true
        case .account: showAccount = true
        default: navigation.destination = ClientTab(rawValue: target.screen.rawValue) ?? .home
        }
        guard let id = target.projectID, target.screen == .workspaces,
              let scope = WorkSessionContext.shared.scope, scope.kind == .account,
              target.owner == EcosystemPublisher.ownerKey(scope) else { return }
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "remote", !parts[1].isEmpty, !parts[2].isEmpty else { return }
        let reference = WorkReference(scope: scope, hostIdentity: parts[1], workspaceID: parts[2],
            kind: target.chatID != nil ? .conversation : target.terminalID != nil ? .terminal : .workspace,
            itemID: target.chatID ?? target.terminalID)
        navigation.restoredRoute = WorkMobileRoute(scope: scope, tab: "workspaces", reference: reference, section: target.section?.rawValue ?? "sessions")
    }

    private func openPendingNewChatRequest() {
        guard let request = navigation.pendingNewChatRequest else { return }
        navigation.pendingNewChatRequest = nil
        switch request {
        case .machineSetup: sessionModels.models(for: WorkSessionContext.shared.scope).setup.open()
        }
    }

    private func openPendingPlace() {
        guard let place = navigation.pendingPlace else { return }
        navigation.pendingPlace = nil
        switch place {
        case .tab(let tab):
            navigation.destination = tab
        case .customizeHome:
            navigation.destination = .home
            navigation.homeEditorRequested = true
        case .customizeWorkspaces:
            navigation.destination = .workspaces
            navigation.workspacesEditorRequested = true
        case .account(let pane, let detail):
            navigation.accountRequest = ClientAccountRequest(pane: pane, detail: detail)
            showAccount = true
        case .device(let machineID):
            navigation.openDevice(machineID: machineID)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        @Bindable var navigation = navigation
        let layoutTicket = navigation.stackGeneration
        let path = Binding(get: { navigation.workspacesPath }, set: {
            navigation.updateWorkspacesPath($0, layout: layoutTicket)
        })
        if #available(iOS 18, *) {
            TabView(selection: $navigation.destination) {
                ForEach(tabCustomization.tabs(including: navigation.destination)) { tab in
                    Tab(tab.label, systemImage: tab.symbol, value: tab) {
                        NavigationStack(path: tab == .workspaces ? path : .constant([])) {
                            tab.content(workspaces: sessionModels.models(for: WorkSessionContext.shared.scope).workspaces)
                                .clientChrome(showAccount: $showAccount)
                                .modifier(ClientRestoredDestination(tab: tab))
                                .modifier(ClientOwnedPushDestination(tab: tab))
                                .navigationDestination(for: ClientFolderPush.self) { $0.destination }
                        }
                    }
                }
            }
            // The bar shrinks out of the way while reading and returns on
            // scroll up. iOS 26 only. It never hides completely.
            .modifier(TabBarMinimizeIfAvailable())
            .clientCompactTabBarOnPad()
        } else {
            TabView(selection: $navigation.destination) {
                ForEach(tabCustomization.tabs(including: navigation.destination)) { tab in
                    NavigationStack(path: tab == .workspaces ? path : .constant([])) {
                        tab.content(workspaces: sessionModels.models(for: WorkSessionContext.shared.scope).workspaces)
                            .clientChrome(showAccount: $showAccount)
                            .modifier(ClientRestoredDestination(tab: tab))
                            .modifier(ClientOwnedPushDestination(tab: tab))
                            .navigationDestination(for: ClientFolderPush.self) { $0.destination }
                    }
                    .tabItem { Label(tab.label, systemImage: tab.symbol) }
                    .tag(tab)
                }
            }
        }
    }
}

enum ClientTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case workspaces
    case insights
    case machines
    case ssh
    case team

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return L10n.text("common.home")
        case .workspaces: return L10n.text("common.projects")
        case .insights: return L10n.text("common.insights")
        case .machines: return L10n.text("common.devices")
        case .team: return L10n.text("common.teams.title")
        case .ssh: return L10n.text("apple.clientrootview.ssh.01c4d3c2")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.fill"
        case .workspaces: return "folder.fill"
        case .insights: return "chart.bar.xaxis"
        case .machines: return "laptopcomputer"
        case .team: return "person.2"
        case .ssh: return "terminal"
        }
    }

    var editorDetail: String {
        switch self {
        case .home: return L10n.text("apple.clientrootview.spend_activity_and_limits.c9d9e601")
        case .workspaces: return L10n.text("apple.clientrootview.folders_and_sessions_on_your_machines.4b93afd1")
        case .insights: return L10n.text("apple.clientrootview.breakdowns_by_model_and_project.9846e926")
        case .machines: return L10n.text("apple.clientrootview.computers_on_your_account.232226fe")
        case .team: return L10n.text("common.teams.directory_detail")
        case .ssh: return L10n.text("apple.clientrootview.saved_servers_and_keys.47db8e47")
        }
    }

    @MainActor
    @ViewBuilder
    func content(workspaces: ClientWorkspacesModel) -> some View {
        switch self {
        case .home: ClientHomeView()
        case .workspaces: ClientWorkspacesView(model: workspaces, handlesNotifications: true)
        case .insights: ClientInsightsView()
        case .machines: ClientDevicesView()
        case .team: ClientTeamView()
        case .ssh: ClientSSHTab()
        }
    }
}

struct ClientSSHTab: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        SSHLibraryView(vaultTier: account.account?.vaultTierForSsh)
    }
}

private struct ClientAuthRetryView: View {
    let message: String?
    let isLoading: Bool
    var onSavedWork: (() -> Void)? = nil
    let onRetry: () -> Void

    private var friendly: FriendlyError? { message.map(FriendlyError.from) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.Space.m) {
                LogoMark(size: 46)
                Text(friendly?.title ?? L10n.text("apple.clientrootview.could_not_reach_your_account.5e7a4b20"))
                    .font(Theme.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(friendly?.message ?? message ?? L10n.text("apple.clientrootview.check_the_connection_and_try_again.5ffff6c5"))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Spacer()
            VStack(spacing: Theme.Space.m) {
                Button {
                    onRetry()
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        ActionIcon.refresh.label(L10n.text("apple.clientrootview.try_again.d8b8392e")).frame(maxWidth: .infinity)
                    }
                }
                .clientProminentStyle()
                .controlSize(.large)
                .disabled(isLoading)
                if let onSavedWork {
                    Button(L10n.text("apple.clientrootview.open_saved_work.513b0142"), .archive, action: onSavedWork)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .tint(Theme.accent)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    func clientChrome(showAccount: Binding<Bool>) -> some View {
        toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AvatarButton { showAccount.wrappedValue = true }
                }
                .clientAvatarChrome()
                ToolbarItem(placement: .topBarTrailing) {
                    ClientWorkSearchButton()
                }
                if ClientKeyboardPresence.shared.isVisible {
                    ToolbarItem(placement: .topBarTrailing) {
                        ClientKeyboardDismissButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ClientConnectionChip()
                }
                ToolbarItem(placement: .principal) {
                    Wordmark(size: 22, fills: false)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

/// iOS 26 shrinks the tab bar on scroll. Earlier systems keep the full bar.
private struct TabBarMinimizeIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}


@MainActor
final class ClientSessionModels {
    @MainActor
    final class Models {
        let workspaces = ClientWorkspacesModel()
        let chats = ClientChatSessions()
        let projectChats = ClientProjectChats()
        let home = HomeModel()
        let insights = ClientInsightsModel()
        let devices = ClientDevicesModel()
        let ssh: ClientSSHWorkbench
        let setup: ClientSetupSession
        init(scope: WorkReference.Scope?) {
            ssh = ClientSSHWorkbench(scope: scope)
            setup = ClientSetupSession(scope: scope)
        }
        func deactivate() { workspaces.deactivate(); chats.deactivate(); ssh.deactivate(); setup.deactivate() }
    }

    private var scope: WorkReference.Scope?
    private var current: Models?
    private var generation: UInt64?

    func models(for scope: WorkReference.Scope?) -> Models {
        if let current, self.scope == scope, generation == WorkSessionContext.shared.generation { return current }
        current?.deactivate()
        let fresh = Models(scope: scope)
        generation = WorkSessionContext.shared.generation
        self.scope = scope
        current = fresh
        return fresh
    }

    func reset() {
        current?.deactivate()
        scope = nil
        generation = nil
        current = nil
    }
}

private extension View {
    func sessionScreens(_ models: ClientSessionModels.Models) -> some View {
        environment(models.home)
            .environment(models.insights)
            .environment(models.devices)
            .environment(models.ssh)
    }
}


private struct ScreenSizeReporter: UIViewRepresentable {
    func makeUIView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.isUserInteractionEnabled = false
        return view
    }

    // Layout and window changes report. Writing from here would publish in
    // the middle of SwiftUI's own update.
    func updateUIView(_ view: ReporterView, context: Context) {}

    final class ReporterView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let size = window?.windowScene?.screen.bounds.size else { return }
            DisplayFit.update(screenSize: size)
        }
    }
}

#endif
