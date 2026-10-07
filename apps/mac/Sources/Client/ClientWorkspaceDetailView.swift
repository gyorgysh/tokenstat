// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit
import WebKit

/// A folder's sessions on a connected host, and the launcher that starts one.
///
/// Pushed from `ClientWorkspaceDetailView`, which is the folder's section
/// list. Launch lives here rather than a level up because starting an agent
/// and watching one are the same job, and the Mac puts them in the same
/// surface for the same reason.
struct ClientWorkspaceSessionsView: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder
    var title: String? = nil

    @State private var sessions: [PtySessionInfo] = []
    @State private var catalog: [RemoteLaunchProfile] = []
    @Environment(ClientWorkspacesModel.self) private var workspaces
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    @State private var owner = WorkSessionContext.shared.scope
    private var openSession: ClientTerminalSession? {
        get { workspaces.activeTerminal }
        nonmutating set { workspaces.activeTerminal = newValue }
    }
    @State private var errorMessage: String?
    @State private var isLaunching = false
    @State private var launchingID: String?
    @State private var installingID: String?
    @State private var showingCatalog = false
    @State private var pendingInstall: RemoteLaunchProfile?
    @State private var pendingHide: RemoteLaunchProfile?
    @State private var browserSession: ProjectBrowserSession?
    @State private var pendingClose: PtySessionInfo?
    @State private var showPort = false
    @State private var portText = "5173"
    @State private var isOpeningPort = false
    /// Read-only launcher state for the Chat tile's count and character.
    @State private var chatPreview = ChatModel()
    /// Open pull requests, for the tile's count. Shared with the section
    /// list, so both say the same number without asking twice.
    @State private var pullCounts = PullCountStore.shared
    /// False until the first `pty.list` and catalog answer land. An empty list
    /// and an unasked question look identical and mean opposite things.
    @State private var loaded = false
    /// Whether the next launch from this phone skips permission prompts.
    /// Remembered per folder on this device, same key the Mac uses.
    @State private var bypassOn = false
    /// How many launch tiles this host had last time, so the grid opens at the
    /// size it will end up. Without it the row painted one Shell tile and then
    /// jumped to eight when the catalog answered. Per host: two machines with
    /// different catalogs must not set each other's placeholder count.
    private var launchTileCountKey: String { "client.launchTileCount.\(peer)" }
    private var rememberedTileCount: Int {
        UserDefaults.standard.object(forKey: launchTileCountKey) as? Int ?? 6
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    private var browserOwner: WorkReference? {
        WorkViewedChange.owner(folderID: workspaceID, peer: peer)
    }


    private var visibility: LauncherVisibility { LauncherVisibility.shared }
    private var visibilityScope: String { peer }

    /// Installed and still on the row. Hidden ones live under +.
    ///
    /// Host `hidden` and this device's defaults both count: a hide on the
    /// Mac lands as catalog.hidden even when this phone has never hid it.
    private var visibleCatalog: [RemoteLaunchProfile] {
        catalog.filter { $0.installed && !isOffGrid($0) }
    }

    /// Not installed, or installed and hidden.
    private var extraCatalog: [RemoteLaunchProfile] {
        catalog.filter { !$0.installed || isOffGrid($0) }
    }

    private func isOffGrid(_ profile: RemoteLaunchProfile) -> Bool {
        profile.hidden == true || visibility.isHidden(profile.id, scope: visibilityScope)
    }

    var body: some View {
        Group {
            if showsBrowserPane, let session = browserSession {
                HStack(spacing: 0) {
                    sessionsColumn
                    ThemeRule.vertical
                    browserPane(session: session)
                        .frame(minWidth: 340, maxWidth: 560)
                }
            } else {
                sessionsColumn
            }
        }
        .background(Theme.background)
        .navigationTitle(title ?? L10n.text("apple.clientworkspacedetailview.sessions.6fa3cbf4"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            // Its own key. The section list this was pushed from pulls on
            // "workspace-<id>", and `ClientRefresh` throttles by key, so
            // sharing one meant a pull here right after a pull there was
            // swallowed while the spinner said otherwise.
            await ClientRefresh.pull("workspace-sessions-\(workspaceID)") { await reload() }
        }
        .onChange(of: folder.id, initial: true) {
            closeBrowser()
            bypassOn = WorkspacePreference.bypassPermissions(for: folder.id)
        }
        .task(id: workspaceID) {
            // Keyed on the folder: the sidebar can swap folders under this
            // screen, and an unkeyed task would keep showing the old one's
            // sessions with the new one's bypass switch.
            // A wireframe that cannot end is worse than the spinner it
            // replaced: it promises an answer is on its way. If the host has
            // not answered in ten seconds, stop promising and show what is
            // known, which is nothing and why.
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, !loaded else { return }
                loaded = true
                if errorMessage == nil {
                    errorMessage = ClientTunnelCopy.waiting(hostName)
                }
            }
            await reload()
            watchdog.cancel()
        }
        .task(id: workspaceID) {
            await chatPreview.load(workspaceID: workspaceID, peer: peer, selectFirst: false)
            #if WORKBENCH_QA
            if ProcessInfo.processInfo.environment["WORKBENCH_BROWSER"] == "1", browserSession == nil {
                // The web view's policy allows about: pages without a host.
                // Real forwarded pages arrive over the tunnel; this proves
                // the beside-work layout, not the tunnel.
                browserSession = ProjectBrowserOwner.make(workspaceID: workspaceID, peer: peer)
                browserSession?.showFixture()
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await recoverAfterNetworkChange() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await recoverAfterNetworkChange() }
        }
        .confirmationDialog(
            L10n.text("apple.clientworkspacedetailview.close_this_session.2b66ce2d"),
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.close"), role: .destructive) {
                if let session = pendingClose {
                    Task { await closeSession(session) }
                }
                pendingClose = nil
            }
            Button(L10n.text("apple.clientworkspacedetailview.keep_it.fdce5da2"), role: .cancel) { pendingClose = nil }
        } message: {
            Text(L10n.text("apple.clientworkspacedetailview.stops_the_process_on_0.7aa0b494", "\(hostName)"))
        }
        .confirmationDialog(
            pendingInstall.map { L10n.text("apple.clientworkspacedetailview.install_0_on_1.534b1069", "\($0.name)", "\(hostName)") } ?? L10n.text("apple.clientworkspacedetailview.install_this_tool.c9c5635e"),
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.clientworkspacedetailview.install.569ca49f")) {
                if let profile = pendingInstall {
                    Task { await install(profile) }
                }
                pendingInstall = nil
            }
            Button(L10n.text("apple.clientworkspacedetailview.not_now.a0e63d7c"), role: .cancel) { pendingInstall = nil }
        } message: {
            Text(L10n.text("apple.clientworkspacedetailview.this_runs_its_official_installer.0cbae9fd"))
        }
        .confirmationDialog(
            pendingHide.map { L10n.text("apple.clientworkspacedetailview.remove_0_from_the_launcher.c6685e92", "\($0.name)") } ?? L10n.text("apple.clientworkspacedetailview.remove_this_tool.fcc2e23e"),
            isPresented: Binding(
                get: { pendingHide != nil },
                set: { if !$0 { pendingHide = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.remove"), role: .destructive) {
                if let profile = pendingHide {
                    Task { await hideOnHost(profile) }
                }
                pendingHide = nil
            }
            Button(L10n.text("apple.clientworkspacedetailview.keep.183f00f4"), role: .cancel) { pendingHide = nil }
        } message: {
            Text(L10n.text("apple.clientworkspacedetailview.the_tool_stays_on_0_you_can_add_it_again_f.b2c85a3e", "\(hostName)"))
        }
        .fullScreenCover(item: Binding(
            get: { showsBrowserPane ? nil : browserSession },
            set: { if $0 == nil, !showsBrowserPane { closeBrowser() } }
        )) { item in
            ClientBrowserScreen(session: item) {
                closeBrowser()
            }
        }
        .sheet(isPresented: $showPort) { browserPortSheet.onAppear { portText = BrowserHistory.shared.portSuggestion(for: browserOwner) } }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in closeBrowser() }
    }

    /// The forwarded browser beside the launcher when the window is regular
    /// both ways (iPad, an open iPhone Duo), instead of over it. Compact layouts keep the full-screen browser. The URL is the
    /// tunnel proxy's, so host localhost resolves through the tunnel and
    /// never touches this device's own localhost. Rotation only moves the
    /// presentation: the port forward and the URL survive it.
    private var showsBrowserPane: Bool {
        browserSession != nil
            && ClientLayout.hasRoom(horizontal: sizeClass, vertical: verticalSizeClass)
    }

    private var sessionsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await reload() }
                    }
                }

                bypassCard
                openCard
                launchCard
                sessionsCard
                ClientProjectSSHRows(peer: peer, workspace: workspaceID)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
    }

    private func browserPane(session: ProjectBrowserSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("common.browser"))
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(Theme.controlGlyph)
                Spacer(minLength: 0)
                Button(action: {
                    closeBrowser()
                }) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityLabel(L10n.text("apple.clientworkspacedetailview.close_browser.dd33033e"))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            ClientBrowserScreen(session: session) {
                closeBrowser()
            }
        }
    }

    private func closeBrowser() {
        browserSession?.close()
        browserSession = nil
    }

    /// Bypass, the switch the Mac keeps next to Launch. Branch lives on the
    /// folder now, one selector per folder instead of one per section.
    private var bypassCard: some View {
        HStack(spacing: Theme.Space.s) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Space.xs)
                    .fill((bypassOn ? Theme.warning : Theme.accent).opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: bypassOn ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(bypassOn ? Theme.warning : Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("apple.clientworkspacedetailview.bypass_permissions.8f7a3f7f"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                Text(bypassOn ? L10n.text("apple.clientworkspacedetailview.on.13001175") : L10n.text("apple.clientworkspacedetailview.off.ca7981b4"))
                    .font(ClientType.label.weight(.medium))
            }
            Spacer(minLength: 0)
            Toggle(
                L10n.text("apple.clientworkspacedetailview.bypass_permissions.8f7a3f7f"),
                isOn: Binding(
                    get: { bypassOn },
                    set: { next in
                        bypassOn = next
                        WorkspacePreference.setBypassPermissions(next, for: folder.id)
                    }
                )
            )
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityValue(bypassOn ? L10n.text("apple.clientworkspacedetailview.on.13001175") : L10n.text("apple.clientworkspacedetailview.off.ca7981b4"))
        .accessibilityHint(
            bypassOn
                ? L10n.text("apple.clientworkspacedetailview.launches_here_skip_permission_prompts_shel.56397e86")
                : L10n.text("apple.clientworkspacedetailview.launches_here_ask_before_acting_turn_on_to.7f74555d")
        )
    }

    private var openCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("common.open"))
                .font(ClientType.sectionTitle)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Theme.Space.s),
                    GridItem(.flexible(), spacing: Theme.Space.s),
                ],
                spacing: Theme.Space.s
            ) {
                ClientOwnedNavigationLink {
                    RemoteHostFeatureGate(feature: .chat, peer: peer, hostName: hostName) {
                        ClientChatView(
                            peer: peer,
                            workspaceID: workspaceID,
                            folderName: folder.name,
                            hostName: hostName,
                            openConversationOnAppear: true
                        )
                    }
                } label: {
                    let recent = chatPreview.mostRecent
                    ClientLauncherDestinationTile(
                        section: .chat,
                        count: chatPreview.chats.count,
                        personaSeed: recent.map(chatPreview.faceSeed(for:)),
                        running: recent?.running == true
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ClientFilesView(peer: peer, workspace: workspaceID, folderName: folder.name)
                } label: {
                    ClientLauncherDestinationTile(section: .files)
                }
                .buttonStyle(.plain)

                Button { showPort = true } label: {
                    ClientLauncherDestinationTile(section: .browser)
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ClientWorkspaceChangesView(
                        peer: peer,
                        workspaceID: workspaceID,
                        folder: folder,
                        hostName: hostName
                    )
                    .id(GitCommitTarget(peer: peer, workspaceID: workspaceID))
                } label: {
                    ClientLauncherDestinationTile(section: .changes)
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ClientWorkspaceHistoryView(
                        peer: peer,
                        workspaceID: workspaceID,
                        folder: folder,
                        hostName: hostName
                    )
                } label: {
                    ClientLauncherDestinationTile(section: .history)
                }
                .buttonStyle(.plain)

                NavigationLink {
                    PullsView(
                        workspaceID: workspaceID,
                        peer: peer,
                        connectionHostName: hostName,
                        workspaceName: folder.name,
                        workspaceIsRemote: true
                    )
                    .navigationTitle(L10n.text("apple.clientworkspacedetailview.pull_requests.d9e3f260"))
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    ClientLauncherDestinationTile(
                        section: .pulls,
                        count: pullCounts.count(workspaceID: workspaceID, peer: peer) ?? 0
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ClientWorkspaceTasksView(
                        peer: peer,
                        workspaceID: workspaceID,
                        hostName: hostName,
                        folderName: folder.name
                    )
                } label: {
                    ClientLauncherDestinationTile(section: .todo)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var launchCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientworkspacedetailview.run_an_agent.b7046310"))
                .font(ClientType.sectionTitle)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Theme.Space.s),
                    GridItem(.flexible(), spacing: Theme.Space.s),
                ],
                spacing: Theme.Space.s
            ) {
                if !loaded, catalog.isEmpty {
                    // Placeholders at the count this host had last time. The
                    // real tiles replace them in place, so nothing moves under
                    // a thumb already reaching for one.
                    ForEach(0..<max(2, rememberedTileCount), id: \.self) { index in
                        ClientLaunchTilePlaceholder(phase: Double(index) * 0.08)
                    }
                } else if catalog.isEmpty {
                    // The host answered and has no catalog: keep the surface
                    // useful. Once one arrives it supplies the host's actual
                    // shell, and the Shell tile is not added a second time.
                    launchTile(RemoteLaunchProfile(
                        id: "shell",
                        name: L10n.text("apple.clientworkspacedetailview.shell.a7332854"),
                        command: "/bin/zsh",
                        args: ["-l"],
                        bypassArgs: [],
                        harnessId: nil,
                        symbol: "terminal",
                        openUrl: nil,
                        installed: true,
                        hidden: false,
                        installCommand: nil
                    ))
                } else {
                    ForEach(visibleCatalog, id: \.id) { profile in
                        launchTile(profile)
                    }
                    if !extraCatalog.isEmpty {
                        ClientMoreTile(showing: showingCatalog) {
                            showingCatalog.toggle()
                        }
                    }
                    if showingCatalog {
                        ForEach(extraCatalog, id: \.id) { profile in
                            launchTile(profile)
                        }
                    }
                }
            }
        }
    }

    private var browserPortSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(L10n.text("apple.clientworkspacedetailview.open_a_local_service.dafb0b3d"))
                        .font(ClientType.screenTitle)
                    Text(L10n.text("apple.clientworkspacedetailview.enter_the_port_a_tool_is_serving_on_0_toke.b0d3a820", "\(hostName)"))
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(L10n.text("apple.clientworkspacedetailview.port.72e9a59f"), text: $portText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.themed)
                ClientRecentBrowserPorts(owner: browserOwner, portText: $portText)
                Spacer(minLength: 0)
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("apple.clientworkspacedetailview.not_now.a0e63d7c"), .dismiss) { showPort = false }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                    Button(L10n.text("common.open"), .browser) { Task { await openPort() } }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(isOpeningPort || BrowserTarget.parsePort(portText) == nil)
                }
            }
            .padding(Theme.Space.l)
            .background(Theme.background)
            .navigationTitle(L10n.text("common.browser"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.background)
    }

    private func openPort() async {
        guard !isOpeningPort, let port = BrowserTarget.parsePort(portText),
              let target = BrowserHistory.shared.target(for: browserOwner, port: port) else { return }
        isOpeningPort = true
        defer { isOpeningPort = false }
        let session = ProjectBrowserOwner.make(workspaceID: workspaceID, peer: peer)
        await session.open(target.url)
        guard session.owner == browserOwner, !Task.isCancelled else {
            session.close()
            return
        }
        if let error = session.error {
            errorMessage = ClientTunnelCopy.display(error, host: hostName)
            session.close()
            return
        }
        guard !session.transportURL.isEmpty else { return }
        closeBrowser()
        browserSession = session
        showPort = false
    }

    @ViewBuilder
    private func launchTile(_ profile: RemoteLaunchProfile) -> some View {
        if profile.installed, !isOffGrid(profile) {
            ClientLaunchTile(
                profile: profile,
                isLaunching: launchingID == profile.id,
                isBusy: isLaunching && launchingID != profile.id
            ) {
                Task { await launch(profile) }
            }
            .contextMenu {
                if profile.id != "shell" {
                    Button(L10n.text("apple.clientworkspacedetailview.remove_from_launcher.b107a73b"), .delete) { pendingHide = profile }
                }
            }
        } else if profile.installed {
            ClientLaunchTile(profile: profile, isMuted: true) {
                Task { await showAgain(profile) }
            }
        } else if profile.installCommand != nil {
            ClientLaunchTile(
                profile: profile,
                isMuted: true,
                isBusy: installingID != nil && installingID != profile.id,
                caption: installingID == profile.id ? L10n.text("apple.clientworkspacedetailview.installing.530bcc35") : profile.name
            ) {
                pendingInstall = profile
            }
        } else {
            ClientLaunchTile(profile: profile, isMuted: true, isBusy: true) {}
        }
    }

    private func install(_ profile: RemoteLaunchProfile) async {
        guard installingID == nil else { return }
        installingID = profile.id
        defer { installingID = nil }
        do {
            let result = try await ClientRemote.launcherInstall(peer: peer, id: profile.id)
            guard result.ok else {
                let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = tail.isEmpty
                    ? L10n.text("apple.clientworkspacedetailview.0_could_not_be_installed_exit_1.cd09fda1", "\(profile.name)", "\(result.exitCode ?? 1)")
                    : tail
                return
            }
            visibility.show(profile.id, scope: visibilityScope)
            catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
            adoptHostHidden()
            if !visibleCatalog.isEmpty {
                UserDefaults.standard.set(visibleCatalog.count, forKey: launchTileCountKey)
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientworkspacedetailview.sessions.6fa3cbf4"))
                .font(ClientType.sectionTitle)
            if !loaded {
                ClientWireframe.Rows(count: 2)
            } else if sessions.isEmpty {
                ClientSectionEmpty(
                    text: L10n.text("apple.clientworkspacedetailview.nothing_running_here.58794718"),
                    art: .sessions,
                    message: L10n.text("apple.clientworkspacedetailview.start_an_agent_from_the_row_above_and_it_o.394f6ed0")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        Button {
                            openExisting(session)
                        } label: {
                            ClientSessionRow(session: session, displayName: terminalName(session))
                        }
                        .buttonStyle(.plain)
                        .modifier(ClientTerminalActions(peer: peer, workspaceID: workspaceID, folderName: folder.name,
                            info: session, onDuplicate: { copied in sessions.append(copied); openExisting(copied) },
                            onClose: { pendingClose = session }))
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Theme.Space.s, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(L10n.text("common.close"), role: .destructive) {
                                pendingClose = session
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(minHeight: CGFloat(sessions.count) * 78)
            }
        }
    }

    private func reload() async {
        errorMessage = nil
        do {
            let all = try await ClientRemote.ptyList(peer: peer)
            sessions = all.filter { session in
                if let ws = session.workspaceID, !ws.isEmpty {
                    return ws == workspaceID
                }
                // Fall back to cwd match when the host did not tag workspace.
                return session.cwd == folder.path || session.cwd.hasPrefix(folder.path + "/")
            }
            catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
            adoptHostHidden()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        // Outside the catch, like every other section screen: the question has
        // been asked and answered, and a refusal is an answer. Without this the
        // wireframe only ever ended on the watchdog, which the `.task` cancels
        // the moment a *successful* load returns, so the screen that worked was
        // the one that pulsed forever.
        loaded = true
    }

    private func recoverAfterNetworkChange() async {
        openSession?.clearTransientTunnelError()
        await reload()
    }

    private func openExisting(_ info: PtySessionInfo) {
        openSession = ClientTerminalSession(peer: peer, info: info)
    }

    private func terminalName(_ info: PtySessionInfo) -> String? {
        guard let scope = WorkSessionContext.shared.scope else { return nil }
        return SidebarTerminalNames.shared.name(for: WorkReference(scope: scope, hostIdentity: peer,
            workspaceID: workspaceID, kind: .terminal, itemID: info.id))
    }

    private func closeSession(_ info: PtySessionInfo) async {
        guard let owner, owner == WorkSessionContext.shared.scope else { return }
        let closing = openSession.flatMap { $0.peer == peer && $0.hostID == info.id ? $0 : nil }
        do {
            if let closing { try await closing.close() }
            else { try await ClientRemote.ptyClose(peer: peer, id: info.id) }
            guard owner == WorkSessionContext.shared.scope else { return }
            if let closing, openSession === closing { openSession = nil }
            sessions.removeAll { $0.id == info.id }
        } catch {
            guard owner == WorkSessionContext.shared.scope else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func adoptHostHidden() {
        let hostHidden = Set(catalog.compactMap { $0.hidden == true ? $0.id : nil })
        if !hostHidden.isEmpty {
            visibility.replace(hostHidden, scope: visibilityScope)
        }
    }

    private func hideOnHost(_ profile: RemoteLaunchProfile) async {
        visibility.hide(profile.id, scope: visibilityScope)
        do {
            try await ClientRemote.launcherHide(peer: peer, id: profile.id)
        } catch {
            // Older host: the local set is the whole answer.
        }
        catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
        adoptHostHidden()
    }

    private func showAgain(_ profile: RemoteLaunchProfile) async {
        visibility.show(profile.id, scope: visibilityScope)
        do {
            try await ClientRemote.launcherShow(peer: peer, id: profile.id)
        } catch {
            // Older host: the local set is the whole answer.
        }
        catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
        adoptHostHidden()
    }

    private func launch(_ profile: RemoteLaunchProfile) async {
        guard profile.installed, !isOffGrid(profile), !isLaunching,
              let owner, owner == WorkSessionContext.shared.scope else { return }
        let layoutGeneration = navigation.layoutGeneration
        isLaunching = true
        launchingID = profile.id
        defer {
            isLaunching = false
            launchingID = nil
        }
        errorMessage = nil
        let dark = colorScheme == .dark
        let pending = ClientTerminalSession(
            peer: peer,
            pendingCommand: profile.command,
            cwd: folder.path,
            rows: 40,
            cols: 100
        )
        openSession = pending
        do {
            // Bypass applies to every launch, including agent harnesses. The
            // chrome switch is the person's choice for the next session.
            let args = bypassOn
                ? profile.args + profile.bypassArgs
                : profile.args
            let info = try await ClientRemote.ptySpawn(
                peer: peer,
                workspaceID: workspaceID,
                command: profile.command,
                args: args,
                rows: 40,
                cols: 100,
                dark: dark
            )
            guard owner == WorkSessionContext.shared.scope else { pending.stop(); return }
            pending.attach(info: info)
            await reload()
        } catch {
            pending.stop()
            guard owner == WorkSessionContext.shared.scope else { return }
            if openSession === pending { openSession = nil }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return
        }
        // The process is already up. A failed browser connection leaves it running.
        guard let page = profile.openUrl, let target = BrowserTarget(page) else { return }
        let browser = ProjectBrowserOwner.make(workspaceID: workspaceID, peer: peer)
        await browser.open(target.url)
        guard browser.owner == browserOwner, !Task.isCancelled else {
            browser.close()
            return
        }
        if let error = browser.error {
            errorMessage = ClientTunnelCopy.display(error, host: hostName)
            browser.close()
            return
        }
        if let proxy = URL(string: browser.transportURL) { _ = await Self.waitForPage(proxy) }
        guard browser.owner == browserOwner, !Task.isCancelled else {
            browser.close()
            return
        }
        guard owner == WorkSessionContext.shared.scope, openSession === pending,
              navigation.layoutGeneration == layoutGeneration else {
            browser.close()
            return
        }
        closeBrowser()
        openSession = nil
        browserSession = browser
    }

    /// True when the harness answered. The local proxy writes 502 while the
    /// peer port is still closed, so that status is "not yet", not ready.
    private static func waitForPage(_ url: URL, timeout: TimeInterval = 40) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            request.httpMethod = "GET"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode != 502 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }
}

// MARK: - Files

struct ClientFilesView: View {
    let peer: String
    let workspace: String
    let folderName: String

    @Environment(ClientEditorStore.self) private var editors
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Tabs when the window has room, and for as long as any tab is open in
    /// this folder. Folding an iPhone Duo with a tab open keeps the strip:
    /// hiding it let the same file open a second time from the host copy,
    /// and whichever of the two was saved last overwrote the other.
    private var usesEditorTabs: Bool {
        ClientLayout.hasRoom(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
            || !editors.tabs(peer: peer, workspace: workspace).isEmpty
    }

    @State private var pathStack: [String] = [""]
    @State private var children: [TreeEntry] = []
    @State private var errorMessage: String?
    @State private var openFile: OpenFile?
    /// False until this folder has answered. An empty list and a folder nobody
    /// has read yet look identical and mean opposite things, so the empty
    /// state waits rather than calling a full folder empty for a moment.
    @State private var loaded = false
    @State private var loadRevision = UUID()
    @State private var openRevision = UUID()
    @State private var visible = false
    @State private var owner = WorkSessionContext.shared.scope

    private var currentPath: String { pathStack.last ?? "" }

    var body: some View {
        Group {
            if usesEditorTabs {
                ClientFileTabs(peer: peer, workspace: workspace, folderName: folderName) {
                    fileList
                }
            } else {
                fileList
            }
        }
    }

    private var fileList: some View {
        List {
            if let errorMessage {
                // The shared card rather than a red line: it knows what to say
                // when the device is offline, and a file list is exactly where
                // a tunnel failure used to arrive as a sentence about sockets.
                ClientErrorCard(message: errorMessage) {
                    Task { await load() }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if loaded, children.isEmpty, errorMessage == nil {
                ClientSectionEmpty(
                    text: L10n.text("apple.clientworkspacedetailview.nothing_in_this_folder.3316d855"),
                    art: .files,
                    message: L10n.text("apple.clientworkspacedetailview.files_an_agent_writes_here_show_up_as_it_w.20c94c7c")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(children) { entry in
                Button {
                    Task { await open(entry) }
                } label: {
                    HStack {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc.text")
                            .foregroundStyle(entry.isDir ? Theme.accent : .secondary)
                        Text(entry.name)
                            .foregroundStyle(entry.ignored ? .secondary : .primary)
                        Spacer()
                        if !entry.isDir, let tab = editors.tab(for: ClientEditorKey(peer: peer, workspace: workspace, path: entry.path)),
                           tab.document.isDirty {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                .accessibilityLabel(L10n.text("apple.clientworkspacedetailview.unsaved_changes.a710c2b9"))
                        }
                        if entry.isDir {
                            Image(systemName: "chevron.right")
                                .font(Theme.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        // The platform's grouped grey is not our dark. Rows paint
        // themselves; the list is only the scroll behind them.
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(currentPath.isEmpty ? folderName : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if pathStack.count > 1 {
                    Button(L10n.text("apple.clientworkspacedetailview.up.55490a4b")) {
                        pathStack.removeLast()
                    }
                }
            }
        }
        .task(id: currentPath) {
            visible = true
            loaded = false
            children = []
            openRevision = UUID()
            await load()
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            loadRevision = UUID()
            openRevision = UUID()
        }
        .sheet(item: $openFile) { file in
            ClientFileEditor(peer: peer, workspace: workspace, path: file.path, content: file.content)
        }
    }

    private func load() async {
        let owner = self.owner
        guard visible, !Task.isCancelled, owner != nil,
              owner == WorkSessionContext.shared.scope else { return }
        let path = currentPath
        let request = UUID()
        loadRevision = request
        errorMessage = nil
        do {
            let fresh = try await ClientRemote.tree(peer: peer, workspace: workspace, path: path)
            guard visible, !Task.isCancelled, request == loadRevision, path == currentPath,
                  owner != nil, owner == WorkSessionContext.shared.scope else { return }
            children = fresh
        } catch {
            guard visible, !Task.isCancelled, request == loadRevision, path == currentPath,
                  owner != nil, owner == WorkSessionContext.shared.scope else { return }
            errorMessage = error.localizedDescription
            children = []
        }
        loaded = true
    }

    private func open(_ entry: TreeEntry) async {
        guard visible, !Task.isCancelled, let owner,
              owner == WorkSessionContext.shared.scope else { return }
        if entry.isDir {
            openRevision = UUID()
            pathStack.append(entry.path)
            return
        }
        let path = currentPath
        let request = UUID()
        openRevision = request
        let key = ClientEditorKey(peer: peer, workspace: workspace, path: entry.path)
        if usesEditorTabs, let tab = editors.tab(for: key), tab.document.isDirty || tab.isSaving {
            editors.select(tab)
            return
        }
        do {
            let file = try await ClientRemote.readFile(peer: peer, workspace: workspace, path: entry.path)
            guard visible, !Task.isCancelled, request == openRevision, path == currentPath,
                  owner == WorkSessionContext.shared.scope else { return }
            if usesEditorTabs {
                editors.adoptSaved(key, content: file.content)
            } else {
                openFile = OpenFile(path: entry.path, content: file.content)
            }
        } catch {
            guard visible, !Task.isCancelled, request == openRevision, path == currentPath,
                  owner == WorkSessionContext.shared.scope else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct OpenFile: Identifiable {
    var id: String { path }
    var path: String
    var content: String
}

/// One file from the host, open for editing.
///
/// Backed by the same `EditorDocument` the Mac editor uses, so the phone gets
/// the same colours from the same parse. `highlight` is a sessionless host
/// method over the buffer rather than the path, so it answers in this process
/// without asking the machine that owns the file.
struct ClientFileEditor: View {
    let peer: String
    let workspace: String
    let path: String

    @State private var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmClose = false
    @State private var find: EditorFindSession
    @State private var conflictHostContent: String?
    @State private var owner = WorkSessionContext.shared.scope
    @State private var visible = false
    @State private var saveGeneration = UUID()
    private let read: ClientEditorStore.Reader
    private let write: ClientEditorStore.Writer

    @MainActor
    init(
        peer: String,
        workspace: String,
        path: String,
        content: String,
        find: EditorFindSession? = nil,
        read: @escaping ClientEditorStore.Reader = { peer, workspace, path in
            try await ClientRemote.readFile(peer: peer, workspace: workspace, path: path).content
        },
        write: @escaping ClientEditorStore.Writer = ClientRemote.writeFile
    ) {
        self.peer = peer
        self.workspace = workspace
        self.path = path
        _document = State(
            initialValue: EditorDocument(workspaceID: workspace, path: path, content: content)
        )
        _find = State(initialValue: find ?? EditorFindSession())
        self.read = read
        self.write = write
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if find.showing {
                    EditorFindBar(find: find)
                }
                if let host = conflictHostContent {
                    EditorConflictCard(document: document, hostContent: host) {
                        resolveConflict(keepMine: false)
                    } onKeep: {
                        resolveConflict(keepMine: true)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                }
                IOSCodeTextView(document: document, find: find)
                    .background(Theme.background)
                    .editorChangedLines(peer: peer, workspace: workspace, document: document)
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("common.close")) {
                            if document.isDirty {
                                confirmClose = true
                            } else {
                                dismiss()
                            }
                        }
                        .disabled(isSaving)
                    }
                    ToolbarItem {
                        Button(L10n.text("apple.clientworkspacedetailview.find_in_file.214c422e"), .search) { find.showing.toggle() }
                            .labelStyle(.iconOnly)
                            .keyboardShortcut("f", modifiers: .command)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? L10n.text("apple.clientworkspacedetailview.saving.23e39291") : L10n.text("common.save")) {
                            Task { await save() }
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(isSaving || !document.isDirty || conflictHostContent != nil)
                    }
                }
                .safeAreaInset(edge: .bottom) { status }
        }
        // Next/previous match stay discoverable when the bar is hidden: the
        // same chord opens the bar, and navigates once it is open. Save and
        // Find ride on their toolbar buttons above.
        .clientShortcuts(findShortcuts)
        // The first parse, before anybody types. Colour is not worth blocking
        // the sheet on, so the text is up either way.
        .task { await document.highlightNow() }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            saveGeneration = UUID()
            isSaving = false
        }
        #if WORKBENCH_QA
        .task {
            if ProcessInfo.processInfo.environment["FILE_DIRTY"] == "1", !document.isDirty {
                document.setText(document.text + "\n// Edited on this device.\n")
                await save()
            }
        }
        #endif
        .interactiveDismissDisabled(document.isDirty || isSaving)
        .confirmationDialog(
            L10n.text("apple.clientworkspacedetailview.discard_changes.85bcf416"),
            isPresented: $confirmClose,
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.clientworkspacedetailview.discard.eb1a70e3"), role: .destructive) { dismiss() }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.clientworkspacedetailview.this_file_has_edits_that_are_not_saved_on.1290524e"))
        }
    }

    /// The line under the buffer: unsaved state, save outcome, and colour
    /// notes. A failed save is the loud case; a file with no grammar is the
    /// quiet one, and saying so beats leaving somebody to wonder why their
    /// config is grey.
    @ViewBuilder
    private var status: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(ClientType.caption)
                .foregroundStyle(Theme.danger)
                .padding()
        } else {
            HStack(spacing: Theme.Space.s) {
                if document.isDirty {
                    Label(L10n.text("apple.clientworkspacedetailview.unsaved.6250d572"), systemImage: "circle.fill")
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.warning)
                } else if let savedAt = document.savedAt {
                    Text(L10n.text("apple.clientworkspacedetailview.saved_0.4f0424e4", "\(savedAt.formatted(date: .omitted, time: .shortened))"))
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
                if !document.changedLines.isEmpty {
                    Text(L10n.text("apple.clientworkspacedetailview.0_changed.d85c3eae", "\(document.changedLines.count)"))
                        .font(ClientType.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let note = document.highlightNote {
                    Text(note)
                        .font(ClientType.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
    }

    /// The find chords for this sheet, routed to the same session the bar
    /// drives. Hidden presses open the bar; open presses move the match.
    private var findShortcuts: [ClientShortcut] {
        let state = EditorShortcutState(
            canNavigate: find.canNavigate,
            findShowing: find.showing
        )
        return [
            .workbench(.findNext, id: "find-next", title: L10n.text("apple.clientworkspacedetailview.find_next.664d6cdf"),
                       enabled: WorkbenchShortcutPolicy.canFindNext(state)) {
                if find.showing {
                    find.goNext()
                } else {
                    find.showing = true
                }
            },
            .workbench(.findPrevious, id: "find-previous", title: L10n.text("apple.clientworkspacedetailview.find_previous.bf0e5179"),
                       enabled: WorkbenchShortcutPolicy.canFindPrevious(state)) {
                if find.showing {
                    find.goPrevious()
                } else {
                    find.showing = true
                }
            },
        ]
    }

    private func save() async {
        let generation = saveGeneration
        guard ownsSave(generation), !isSaving, conflictHostContent == nil else { return }
        isSaving = true
        defer { if saveGeneration == generation { isSaving = false } }
        let host: String
        do {
            host = try await read(peer, workspace, path)
        } catch {
            guard ownsSave(generation) else { return }
            errorMessage = L10n.text("apple.clientworkspacedetailview.could_not_re_read_this_file_on_that_comput.dacb7165")
            return
        }
        guard ownsSave(generation) else { return }
        let draft = document.text
        if host != draft, host != document.savedText {
            errorMessage = nil
            conflictHostContent = host
            return
        }
        if host == draft {
            document.markSaved(content: draft)
            errorMessage = nil
            return
        }
        let sent = draft
        do {
            try await write(peer, workspace, path, sent)
            guard ownsSave(generation) else { return }
            document.markSaved(content: sent)
            errorMessage = nil
            NotificationCenter.default.post(
                name: .clientFileDidChange,
                object: ClientFileChangeNotice(peer: peer, workspace: workspace, path: path)
            )
        } catch {
            guard ownsSave(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func resolveConflict(keepMine: Bool) {
        let generation = saveGeneration
        guard ownsSave(generation), conflictHostContent != nil, !isSaving else { return }
        if keepMine {
            // Explicit choice: write the draft through without re-verifying.
            // Re-reading first would raise the same conflict again.
            conflictHostContent = nil
            errorMessage = nil
            let sent = document.text
            isSaving = true
            Task {
                defer { if saveGeneration == generation { isSaving = false } }
                guard ownsSave(generation) else { return }
                do {
                    try await write(peer, workspace, path, sent)
                    guard ownsSave(generation) else { return }
                    document.markSaved(content: sent)
                    NotificationCenter.default.post(
                        name: .clientFileDidChange,
                        object: ClientFileChangeNotice(peer: peer, workspace: workspace, path: path)
                    )
                } catch {
                    guard ownsSave(generation) else { return }
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            if let host = conflictHostContent {
                document.adopt(saved: host)
            }
            conflictHostContent = nil
            errorMessage = nil
        }
    }

    private func ownsSave(_ generation: UUID) -> Bool {
        visible && !Task.isCancelled && saveGeneration == generation
            && owner != nil && owner == WorkSessionContext.shared.scope
    }
}

// MARK: - Browser

struct ClientBrowserScreen: View {
    @Bindable var session: ProjectBrowserSession
    var onClose: () -> Void
    @State private var address: String
    @State private var loadError: String?
    @State private var reloadToken = 0

    init(session: ProjectBrowserSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _address = State(initialValue: session.targetURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L10n.text("apple.clientworkspacedetailview.url_or_port.8de6b795"), text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { openAddress() }
                    .font(ClientType.caption)
                    .padding(Theme.Space.s)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Menu {
                    ForEach(session.recentPorts, id: \.self) { port in
                        Button(String(port), .browser) { address = "http://127.0.0.1:\(port)/" }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .disabled(session.recentPorts.isEmpty)
                .accessibilityLabel(L10n.text("apple.clientworkspacedetailview.recent_project_ports.b18529b8"))
                Button(action: openAddress) {
                    Image(systemName: "arrow.right.circle")
                        .frame(minWidth: 32, minHeight: 44)
                }
                    .font(ClientType.caption.weight(.semibold))
                    .accessibilityLabel(L10n.text("apple.clientworkspacedetailview.open_address.abc6bf46"))
                    .disabled(session.isOpening)
                Button {
                    loadError = nil
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 32, minHeight: 44)
                }
                .font(ClientType.caption.weight(.semibold))
                .accessibilityLabel(L10n.text("apple.clientworkspacedetailview.reload.bdc090ec"))
                Button(L10n.text("common.done"), .done, action: onClose)
                    .font(ClientType.caption.weight(.semibold))
            }
            .padding(Theme.Space.m)
            if let error = session.error ?? loadError {
                Text(error)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
            }
            ClientWebView(urlString: session.transportURL, reloadToken: reloadToken, navigationGeneration: session.navigationGeneration, loadRevision: session.loadRevision,
                onError: { loadError = $0 }, onURLChange: { actual, completion in
                    session.observed(actual, generation: completion.generation, registered: completion.registered,
                        nativeHistoryID: completion.nativeHistoryID)
                },
                onLocalNavigation: { request, isMainFrame, traversal in
                    session.intercept(request, isMainFrame: isMainFrame, historyItemID: traversal?.id,
                        historyDirection: traversal?.direction ?? 0)
                },
                historyItemToRestore: session.historyItemToRestore,
                onPageHistoryChange: { mutation, items, id, generation in
                    session.observedHistory(mutation, items: items, currentID: id, generation: generation)
                },
                onPageHistoryTraverse: { delta, generation in session.traverseHistory(delta, generation: generation) })
                .id(session.id)
        }
        .background(Theme.background)
        .onChange(of: session.targetURL) { _, target in address = target }
    }

    private func openAddress() {
        loadError = nil
        Task { await session.open(address) }
    }
}

struct ClientWebView: UIViewRepresentable {
    let urlString: String
    var reloadToken = 0
    var navigationGeneration = 0
    var loadRevision = 0
    var onError: (String) -> Void = { _ in }
    var onURLChange: (String, BrowserNavigationEpoch.Completion) -> Bool = { _, _ in true }
    var onLocalNavigation: ((URLRequest, Bool, BrowserPageHistoryTraversal?) -> Bool)?
    var historyItemToRestore: UUID?
    var onPageHistoryChange: ((BrowserPageHistoryMutation, [BrowserPageHistoryItem], UUID, Int) -> Bool)?
    var onPageHistoryTraverse: ((Int, Int) -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError, onURLChange: onURLChange, onLocalNavigation: onLocalNavigation,
            onPageHistoryChange: onPageHistoryChange, onPageHistoryTraverse: onPageHistoryTraverse)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        context.coordinator.pageHistory.install(in: configuration)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.requestedURL = urlString
        context.coordinator.reloadToken = reloadToken
        context.coordinator.loadRevision = loadRevision
        context.coordinator.epochs.current = navigationGeneration
        context.coordinator.pageHistory.attach(view, generation: navigationGeneration)
        if let url = URL(string: urlString), !urlString.isEmpty {
            context.coordinator.epochs.register(view.load(URLRequest(url: url)), generation: navigationGeneration)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.onURLChange = onURLChange
        context.coordinator.onLocalNavigation = onLocalNavigation
        context.coordinator.onPageHistoryChange = onPageHistoryChange
        context.coordinator.pageHistory.onTraverse = onPageHistoryTraverse
        context.coordinator.epochs.current = navigationGeneration
        context.coordinator.pageHistory.attach(view, generation: navigationGeneration)
        let explicitLoad = context.coordinator.loadRevision != loadRevision
        if explicitLoad || context.coordinator.requestedURL != urlString {
            context.coordinator.requestedURL = urlString
            context.coordinator.loadRevision = loadRevision
            if let url = URL(string: urlString), !urlString.isEmpty, explicitLoad || view.url?.absoluteString != urlString {
                let navigation = context.coordinator.pageHistory.load(view, url: url, restoring: historyItemToRestore)
                context.coordinator.epochs.register(navigation, generation: navigationGeneration)
            }
        }
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            context.coordinator.epochs.register(view.reload(), generation: navigationGeneration)
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        coordinator.pageHistory.dismantle(view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onError: (String) -> Void
        var onURLChange: (String, BrowserNavigationEpoch.Completion) -> Bool
        var onLocalNavigation: ((URLRequest, Bool, BrowserPageHistoryTraversal?) -> Bool)?
        var onPageHistoryChange: ((BrowserPageHistoryMutation, [BrowserPageHistoryItem], UUID, Int) -> Bool)?
        var onPageHistoryTraverse: ((Int, Int) -> Bool)?
        lazy var pageHistory = BrowserNativeHistory(onChange: { [weak self] mutation, items, id, generation in
            guard let self, self.onPageHistoryChange?(mutation, items, id, generation) == true else { return false }
            self.requestedURL = items.first(where: { $0.id == id })?.url ?? self.requestedURL
            return true
        }, onTraverse: onPageHistoryTraverse, onAbandon: { [weak self] navigation in
            self?.epochs.abandonIfNotStarted(navigation)
        })
        var requestedURL = ""
        var reloadToken = 0
        var loadRevision = 0
        var epochs = BrowserNavigationEpoch()

        init(onError: @escaping (String) -> Void, onURLChange: @escaping (String, BrowserNavigationEpoch.Completion) -> Bool,
             onLocalNavigation: ((URLRequest, Bool, BrowserPageHistoryTraversal?) -> Bool)?,
             onPageHistoryChange: ((BrowserPageHistoryMutation, [BrowserPageHistoryItem], UUID, Int) -> Bool)?,
             onPageHistoryTraverse: ((Int, Int) -> Bool)?) {
            self.onError = onError
            self.onURLChange = onURLChange
            self.onLocalNavigation = onLocalNavigation
            self.onPageHistoryChange = onPageHistoryChange
            self.onPageHistoryTraverse = onPageHistoryTraverse
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if onLocalNavigation?(action.request, action.targetFrame?.isMainFrame != false, pageHistory.traversal(for: action, in: webView)) == true {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(Self.allows(action.request.url) ? .allow : .cancel)
        }

        static func allows(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased() else { return false }
            if scheme == "about" { return true }
            if let host = url.host, BrowserTarget.isLoopback(host) { return BrowserTarget(url.absoluteString) != nil }
            return scheme == "https" && (url.host == "tokenstat.ai" || url.host?.hasSuffix(".tokenstat.ai") == true)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            _ = epochs.started(navigation)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard var completion = epochs.finish(navigation) else { return }
            completion.nativeHistoryID = pageHistory.report(.pop, in: webView, generation: completion.generation)
            if let url = webView.url?.absoluteString {
                if onURLChange(url, completion) { requestedURL = url }
            }
            pageHistory.report(.snapshot, in: webView, generation: completion.generation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard epochs.finish(navigation) != nil else { return }
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard epochs.finish(navigation) != nil else { return }
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard action.targetFrame == nil, let url = action.request.url else { return nil }
            if onLocalNavigation?(action.request, true, nil) == true { return nil }
            if Self.allows(url) { epochs.register(webView.load(action.request), generation: epochs.current) }
            return nil
        }
    }
}

#endif
