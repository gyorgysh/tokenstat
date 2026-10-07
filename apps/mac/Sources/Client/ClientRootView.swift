// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
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
    /// iPad and iPhone want different intros. See `signedOut`.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var launch = LaunchState()
    /// One account model for the whole client. The avatar reads it, the sheet
    /// edits it, and every screen that needs a tier or a machine list reads the
    /// same copy rather than starting a second sign-in state.
    @State private var account = AccountModel()
    @State private var webAuth = ClientWebAuth()
    /// Whether this phone can reach the internet. Every screen in the client is
    /// account plane, which means every screen depends on the network, so the
    /// answer belongs at the root rather than in each of them.
    @State private var connectivity = ConnectivityModel()
    /// What the app believes about the network, folded from the internet, the
    /// service and the tunnel. Every screen reads this one rather than each
    /// deciding for itself. See `ConnectionModel`.
    @State private var connection = ConnectionModel()
    /// Whether this iPad has a keyboard or a trackpad attached, which is what
    /// decides between the tab bar and the sidebar. See `ClientLayout`.
    @State private var input = PointerKeyboardModel()
    /// Where the person is, held above both layouts so a keyboard being
    /// attached or detached does not land them somewhere else.
    @State private var navigation = ClientNavigationModel()
    /// This device's tabs, shared with the editor in the account sheet.
    @State private var tabCustomization = ClientTabCustomization.shared
    @State private var editors = ClientEditorStore(
        write: ClientRemote.writeFile,
        read: { peer, workspace, path in
            try await ClientRemote.readFile(peer: peer, workspace: workspace, path: path).content
        },
        sessionID: { WorkSessionContext.shared.scope.map(AnyHashable.init) }
    )
    /// The account sheet, opened from the avatar rather than from a tab. See
    /// `AvatarButton`.
    @State private var showAccount = false
    @State private var store = ClientStore()
    @State private var notificationOpen = NotificationOpen.shared
    @State private var ecosystemNavigation = EcosystemNavigation.shared
    @State private var savedAccess = SavedWorkAccess.shared

    /// The door for a phone or an iPad with no account on it.
    ///
    /// **The app is behind the sign-in, not beside it.** Every screen here
    /// answers a question about an account, so a signed out client that can
    /// reach the tabs is four empty screens and a sign-in card repeated on
    /// each of them. One door instead: the intro on a first run, the sign-in
    /// screen after that.
    ///
    /// One root-owned intro sheet keeps its page during a fold or rotation.
    /// The system form sizing supplies a readable width on larger windows.
    @State private var introProgress = ClientIntroProgress()

    @ViewBuilder
    private var signedOut: some View {
        ClientLoginView()
            .transition(.opacity)
            .sheet(isPresented: Binding(
                get: { !hasOnboarded },
                // Explicit swipe dismissal is also a way to skip the intro.
                set: { if !$0 { hasOnboarded = true } }
            )) {
                ClientOnboarding(flow: introProgress)
                    .clientIntroSheetSizing()
            }
    }

    /// Set once the intro has been seen or skipped. A signed-in phone never
    /// sees it, so a reinstall onto an account that already exists does not get
    /// pitched the product it is already using.
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false

    /// The layout the person picked, which beats what the app worked out.
    /// Written by the account sheet, read here and nowhere else.
    @AppStorage("client.layoutMode") private var layoutPreference = ClientLayoutPreference.automatic.rawValue

    /// The width of the window this scene is in, which the layout decision
    /// needs and no environment value reports. Read once at the root rather
    /// than by every screen.
    @State private var windowWidth: CGFloat = 0

    /// The projects connection, above the layout branch so both layouts use
    /// the same one. See `ClientSessionModels`.
    @State private var sessionModels = ClientSessionModels()

    /// Where the person was when the layout last swapped, waiting for the
    /// new layout to be on screen. See the `.task(id: layout)` below.
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

    /// Reopen a conversation the way a person reaches it: its folder's chat
    /// screen, with the conversation selected in it. Back then lands on that
    /// folder's chats, as it would have before the layout changed. False
    /// when the folder is not known yet, so the caller falls back to the
    /// conversation on its own.
    private func reopenConversation(_ route: WorkMobileRoute) -> Bool {
        guard let reference = route.reference, reference.kind == .conversation,
              let chatID = reference.itemID, !chatID.isEmpty else { return false }
        let workspaces = sessionModels.models(for: route.scope).workspaces
        // `folders` is the connected computer's. A chat on another one must
        // not be matched to a folder here by its id alone.
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

    var body: some View {
        Group {
            // Three doors after the host is up, not two: still checking,
            // could not check (usually offline), and a definitive answer.
            // Folding a failed check into "signed out" was the cold-start bug
            // that flashed Sign in for a phone that still had a token.
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
                    // Hiding the open tab lands on the first visible one
                    // rather than on a blank bar. The editor refuses the last
                    // tab, so this is a move, never a guess at nothing.
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
        // The layout swap is animated like the other door changes: a keyboard
        // being attached should read as the app rearranging itself, not as a
        // new screen appearing from nowhere.
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
        .task {
            connectivity.start()
            input.start()
            connection.attach(connectivity)
            // Every call that leaves this device reports here. Installed once,
            // at the root, so no screen has to remember to.
            BridgeObserver.report = { method, peer, error in
                guard let plane = NetworkPlane.of(method: method) else { return }
                Task { @MainActor in
                    connection.note(plane: plane, peer: peer, failure: error)
                }
            }
            // Offline, a call that has to leave the device fails now rather
            // than after its patience budget. See `BridgeObserver.precheck`.
            BridgeObserver.precheck = { method in
                guard NetworkGate.isOffline, NetworkPlane.of(method: method) != nil else {
                    return nil
                }
                return BridgeError.core(
                    code: "offline",
                    message: L10n.text("apple.clientrootview.this_device_is_offline.84b7cf97")
                )
            }
            // Sign-in presents over the app rather than handing the URL to
            // Safari and hoping somebody comes back. See `ClientWebAuth`.
            account.signInPresenter = { webAuth.start($0) }
            // The app closes the window the app opened. Without this the sheet
            // sits there after a successful approval, on top of a screen that
            // has already signed in behind it.
            account.signInDismisser = { webAuth.cancel() }
            store.currentAccount = { account.account }
            store.onAccountChange = { updated in
                account.account = updated
                NotificationCenter.default.post(name: .tokenstatEntitlementDidChange, object: nil)
                Task { _ = try? await Bridge.reconsiderPlan() }
            }
            store.start()
            await launch.prepare()
            // Name this phone before anything asks the account who is on it.
            // See `ClientDeviceName`.
            await ClientDeviceName.publish()
            await account.load()
            if let signed = account.account {
                await store.finishPendingIntent(with: signed)
            }
        }
        .onChange(of: navigation.currentRoute) { _, _ in navigation.saveRoute() }
        .onChange(of: layout) { _, _ in
            navigation.layoutGeneration &+= 1
            navigation.stackGeneration &+= 1
            // An opening without a selected chat still belongs to this root
            // push. Keep its snapshot while its shared producer finishes.
            if navigation.pushedChat != nil, navigation.chatHandoff.reader == nil {
                layoutHandoff = nil
                return
            }
            // Keep an exact destination above the subtree being replaced.
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
            // A compact/regular project swap can happen without changing
            // the root's tab/sidebar mode. Async launch handoffs follow both.
            navigation.layoutGeneration &+= 1
        }
        // And put it back once the new layout is mounted. Set only in the
        // same update as the swap, the route could be cleared by the old
        // layout tearing down, or offered to a navigation stack that did
        // not exist yet: folding an iPhone Duo on an open chat landed on the
        // tab's top level instead of the chat.
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
                // Folder readers keep their list/back route when metadata is
                // known. A missing folder still uses this exact source below.
                if reader?.key.conversation == nil, reopenConversation(route) { return }
                navigation.restoredChatReader = reader?.matches(route) == true ? reader : nil
                if let tab = ClientTab(rawValue: route.tab), tabCustomization.visibleTabs.contains(tab),
                   navigation.destination != tab {
                    navigation.destination = tab
                }
                if navigation.restoredRoute != route { navigation.restoredRoute = route }
            }
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
        }
        .onContinueUserActivity("ai.tokenstat.open") { activity in
            if let value = activity.userInfo?["url"] as? String, let url = URL(string: value) { ecosystemNavigation.receive(url) }
        }
        .onOpenURL { ecosystemNavigation.receive($0) }
        .onChange(of: ecosystemNavigation.pending, initial: true) { _, _ in openEcosystemDestination() }
        .onChange(of: account.signedIn) { _, signedIn in
            openEcosystemDestination()
            if !signedIn {
                editors.reset()
                sessionModels.reset()
            }
            guard signedIn, let signed = account.account else { return }
            Task { await store.finishPendingIntent(with: signed) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            // Cold start offline leaves authNeedsRetry. Signed-in screens also
            // want a fresh me after the network returns, and the tunnel session
            // this phone holds should reconnect now, not after its backoff.
            connection.reset()
            Task { await account.load() }
            Task { await Bridge.nudgeTunnel(reconnect: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            sessionModels.models(for: WorkSessionContext.shared.scope).ssh.setForeground(phase == .active)
            if phase == .active { EcosystemWatchSync.shared.activate() }
            if phase != .active { navigation.saveRoute() }
            guard phase == .active, account.signedIn else { return }
            Task { await Bridge.nudgeTunnelOnForeground() }
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
        .modifier(ClientProjectChatActions())
        .modifier(ClientSSHPresentations(workbench: sessionModels.models(for: WorkSessionContext.shared.scope).ssh,
            tier: account.account?.vaultTierForSsh))
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
    }

    /// System routes wait for sign-in and reuse the saved-route availability
    /// flow for a project on a remote host.
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

    /// Go where search was asked to go, now that search has closed.
    /// The account sheet shares this presenter, so tabs and settings wait for
    /// search dismissal instead of rearranging the interface behind it.
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
            // And on iPad it is the same floating bar rather than a pill in
            // the top bar. See `CompactTabBarOnPad`.
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

/// The four destinations the client has.
///
/// Account is not among them on purpose. It lives behind the avatar in the top
/// bar, which is where a thumb already goes looking for it, and that keeps a
/// tab for something a person actually opens the app to see.
///
/// **Limits used to have a tab and gave it up.** The phone exists to answer two
/// questions, spend and what is left, and both belong on the screen that opens.
/// A tab for the second one meant somebody had to know it was there. It is a
/// card on Home now, which is also what the original plan said before the tab
/// bar tempted it out.
///
/// What took the free slot is **Workspaces**, which is the machine plane's front
/// door: folders on a machine that is awake, and later the sessions running in
/// them. That is the thing this app cannot do yet and the thing people will open
/// it hoping to find, so it gets a place rather than being buried under
/// Machines. Machines stays: a device is not a folder, and the account's tier,
/// its reach and its last-seen times belong to devices.
enum ClientTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case workspaces
    case insights
    case machines
    /// Saved servers, for somebody who lives in them. Opt-in on the phone
    /// and on from the start on the iPad: the phone bar stays the familiar
    /// four until it is switched on in the tab editor.
    case ssh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return L10n.text("common.home")
        case .workspaces: return L10n.text("common.projects")
        case .insights: return L10n.text("common.insights")
        case .machines: return L10n.text("common.devices")
        case .ssh: return L10n.text("apple.clientrootview.ssh.01c4d3c2")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.fill"
        case .workspaces: return "folder.fill"
        case .insights: return "chart.bar.xaxis"
        case .machines: return "laptopcomputer"
        case .ssh: return "terminal"
        }
    }

    /// One line in the tab editor, saying what the tab is for.
    var editorDetail: String {
        switch self {
        case .home: return L10n.text("apple.clientrootview.spend_activity_and_limits.c9d9e601")
        case .workspaces: return L10n.text("apple.clientrootview.folders_and_sessions_on_your_machines.4b93afd1")
        case .insights: return L10n.text("apple.clientrootview.breakdowns_by_model_and_project.9846e926")
        case .machines: return L10n.text("apple.clientrootview.computers_on_your_account.232226fe")
        case .ssh: return L10n.text("apple.clientrootview.saved_servers_and_keys.47db8e47")
        }
    }

    /// Built on the main actor, like every other view. Said out loud because
    /// this is an enum member rather than a `View`, so nothing else says it.
    @MainActor
    @ViewBuilder
    func content(workspaces: ClientWorkspacesModel) -> some View {
        switch self {
        case .home: ClientHomeView()
        case .workspaces: ClientWorkspacesView(model: workspaces, handlesNotifications: true)
        case .insights: ClientInsightsView()
        case .machines: ClientDevicesView()
        case .ssh: ClientSSHTab()
        }
    }
}

/// SSH as a tab, with the account's vault tier like the Devices row passes.
/// Shared with the sidebar layout, which draws the same destination.
struct ClientSSHTab: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        SSHLibraryView(vaultTier: account.account?.vaultTierForSsh)
    }
}

/// Could not finish the first account check (almost always offline).
///
/// Separate from the login door on purpose: Sign in is for "we know you are
/// out". This is for "we could not ask". A Retry is the honest control.
private struct ClientAuthRetryView: View {
    let message: String?
    let isLoading: Bool
    var onSavedWork: (() -> Void)? = nil
    let onRetry: () -> Void

    /// The failure in the app's own words. Raw transport text ("unknown
    /// status code", edge numbers) never leads on this screen.
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
    /// The top bar every client screen shares: the avatar, the wordmark, and
    /// room for exactly one contextual control.
    ///
    /// A modifier rather than a wrapper view, so each screen keeps its own
    /// scroll view as the direct child of the navigation stack. That is what
    /// lets content scroll under the glass instead of stopping at its edge.
    func clientChrome(showAccount: Binding<Bool>) -> some View {
        toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AvatarButton { showAccount.wrappedValue = true }
                }
                .clientAvatarChrome()
                // The wordmark, not the screen's name. The tab bar already
                // says which screen this is, and the middle of the top bar is
                // the one piece of pure brand the client gets.
                // The one global word about the network, and only when there
                // is one to say. See `ClientConnectionChip`.
                ToolbarItem(placement: .topBarTrailing) {
                    ClientWorkSearchButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ClientConnectionChip()
                }
                ToolbarItem(placement: .principal) {
                    // Larger than the Mac's sidebar lockup, and not filling:
                    // this is the one brand on the screen and it has a whole
                    // bar to itself, where the sidebar size read as a caption.
                    // `fills` off so it centres instead of pushing right.
                    //
                    // Windowed too. The iPad's traffic lights take the start
                    // of this row, not its middle, and this bar is the whole
                    // window wide, so the centre is still free. Dropping the
                    // brand here left the bar with an avatar at one end and a
                    // search button at the other.
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


/// The signed-in session's screen models, shared by both layouts.
///
/// An iPhone Duo swaps the sidebar and the tabs on every fold. Models owned
/// by either layout went with it: opening the phone dialled the Mac again,
/// and Home, Insights and Devices drew their placeholders while they read
/// everything a second time. The Mac keeps these for the life of the window,
/// and so does this. Keyed by work scope, the key the layouts are rebuilt on,
/// so another scope still starts fresh. A cache read from the body, which is
/// why it is a plain class: handing back the models must not count as a change.
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
        init(scope: WorkReference.Scope?) { ssh = ClientSSHWorkbench(scope: scope) }
        func deactivate() { workspaces.deactivate(); ssh.deactivate() }
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

    /// Drop everything on sign-out, as unmounting the layouts used to.
    func reset() {
        current?.deactivate()
        scope = nil
        generation = nil
        current = nil
    }
}

private extension View {
    /// The screens that read their model from the environment.
    func sessionScreens(_ models: ClientSessionModels.Models) -> some View {
        environment(models.home)
            .environment(models.insights)
            .environment(models.devices)
            .environment(models.ssh)
    }
}


/// Tells `DisplayFit` the size of the screen this window is on.
///
/// Sized with the window, so it lays out again on every resize, a rotation
/// and an iPhone Duo opening or folding included, and reads the screen from
/// the window's own scene each time.
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
