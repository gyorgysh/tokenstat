// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Folders and running sessions on a host that is awake (P5 machine plane).
///
/// Account plane answers spend and limits while every laptop is asleep. This
/// tab is the opposite: it needs a live tunnel to a host. Once connected,
/// folders open into a Terminus-style surface: sessions, files, ports, tty.
struct ClientWorkspacesView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(ClientStore.self) private var store
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ClientWorkspacesModel
    @State private var pendingClose: PtySessionInfo?
    @State private var notificationOpen = NotificationOpen.shared
    @State private var showSetup = false
    @State private var customizing = false
    @State private var layout = WorkspacesLayout.shared
    /// The folder handoff this view has already pushed, so a reconnect does
    /// not push it again after somebody backed out of it.
    @State private var handledFolderHandoff: String?
    /// Which folder chooser is showing, if any. Same question as the device
    /// page: chats and sessions live inside folders.
    @State private var starting: WorkspaceSection?
    // Per-host, not global: each host card owns its row. A global key would
    // make every toggle move together, which is the extra card in the
    // screenshot. The rule itself lives on the model, because the iPad's
    // sidebar owns a model without ever mounting this view.
    private func autoConnectBinding(for peerKey: String) -> Binding<Bool> {
        Binding(
            get: { ClientWorkspacesModel.isAutoConnectEnabled(for: peerKey) },
            set: {
                UserDefaults.standard.set(
                    $0, forKey: ClientWorkspacesModel.autoConnectKey(for: peerKey)
                )
            }
        )
    }

    private func isAutoConnectEnabled(for peerKey: String) -> Bool {
        ClientWorkspacesModel.isAutoConnectEnabled(for: peerKey)
    }

    /// The sidebar layout owns one model for the whole window: its tree and
    /// this screen are one connection, not two dialling the same machine.
    /// Tab mode passes nothing and gets its own, as it always had.
    /// Nil means "make your own". A default argument cannot construct one:
    /// the model is main-actor isolated and a default is evaluated where the
    /// caller is, which is not always here.
    ///
    /// When this view owns the model, it also consumes notification taps.
    /// The sidebar passes its model in and handles those itself, so two
    /// surfaces do not open the same thread.
    private let handlesNotifications: Bool

    @MainActor
    init(model: ClientWorkspacesModel? = nil) {
        handlesNotifications = model == nil
        _model = State(initialValue: model ?? ClientWorkspacesModel())
    }

    private var remoteAllowed: Bool {
        if let remote = account.account?.canRemote { return remote }
        let tier = account.account?.tier?.lowercased()
        return ["patron", "legend"].contains(tier)
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        ClientErrorCard(message: message) {
                            Task { await model.refresh(account: account.account) }
                        }
                    }
                    if let host = model.awaitingAccessHost {
                        ClientAwaitingAccessCard(
                            hostName: host,
                            isHeadless: isHeadlessHost(named: host)
                        )
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
                            actionTitle: L10n.text("apple.clientworkspacesview.see_plans.d9898933"),
                            actionIcon: .plans,
                            action: {
                                store.showPaywall = true
                            },
                            art: .remoteGate
                        )
                    } else if model.hosts.isEmpty {
                        // Not "no hosts". The hole is a machine, and the thing
                        // that fills it is one button away rather than three
                        // sentences of instructions about another computer.
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: L10n.text("apple.clientworkspacesview.no_machine_yet.3ea83dc9"),
                            message: L10n.text("apple.clientworkspacesview.tokenstat_runs_agents_on_a_machine_that_st.93fe9732"),
                            actionTitle: L10n.text("apple.clientworkspacesview.set_up_a_machine.43e10e13"),
                            actionIcon: .connect,
                            action: { showSetup = true },
                            art: .connect
                        )
                    } else {
                        ClientSectionTitle(title: L10n.text("apple.clientworkspacesview.computers_on_your_account.232226fe"), mark: "mark_host")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)

                        ForEach(model.hosts) { host in
                            hostCard(host)
                        }
                    }

                    thisDeviceRow

                    // What the connection is, on the screen that makes them.
                    ClientSecurityCard(
                        peerKey: model.connectedKey,
                        peerName: model.hosts.first { $0.peerKey == model.connectedKey }?.name
                    )

                    if model.connectedKey != nil {
                        if let peer = model.connectedKey,
                           let host = model.hosts.first(where: { $0.peerKey == peer }) {
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
            .background(Theme.background)
            .sheet(item: $starting) { section in
                if let peer = model.connectedKey,
                   let host = model.hosts.first(where: { $0.peerKey == peer }) {
                    ClientFolderChooserSheet(
                        hostName: host.name,
                        folders: model.folders,
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
            .onChange(of: navigation.workspacesEditorRequested, initial: true) { _, requested in
                guard requested else { return }
                navigation.workspacesEditorRequested = false
                customizing = true
            }
            .fullScreenCover(isPresented: $showSetup) {
                ClientSetupWizard()
            }
            .navigationTitle(L10n.text("common.projects"))
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
            // When the host list refreshes and the last host comes online
            // after being offline (Mac wakes, lid opens), try again. This is
            // what makes "keep trying until online" work without a timer.
            .onChange(of: model.hosts) { _, _ in
                Task { await model.autoConnectLastHost() }
            }
            // A handoff can set only the folder, with no push (setup ends by
            // opening a project). The sidebar reads `folderID` itself; this
            // layout has no such read, so turn it into the push this stack
            // understands once the host has answered and the folder is known.
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
                guard let key = model.connectedKey ?? UserDefaults.standard.string(forKey: "client.lastConnectedHost"),
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
            .fullScreenCover(item: $model.activeTerminal) { session in
                ClientTerminalScreen(
                    session: session,
                    hostName: model.hosts.first { $0.peerKey == model.connectedKey }?.name ?? "",
                    onClose: { model.activeTerminal = nil },
                    onClosedProcess: {
                        Task { await model.refresh(account: account.account) }
                    }
                )
            }
            .confirmationDialog(
                L10n.text("apple.clientworkspacesview.close_this_session.2b66ce2d"),
                isPresented: Binding(
                    get: { pendingClose != nil },
                    set: { if !$0 { pendingClose = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.text("common.close"), role: .destructive) {
                    if let session = pendingClose {
                        Task { await model.closeSession(session) }
                    }
                    pendingClose = nil
                }
                Button(L10n.text("apple.clientworkspacesview.keep_it.fdce5da2"), role: .cancel) { pendingClose = nil }
            } message: {
                Text(model.hosts.first { $0.peerKey == model.connectedKey }.map {
                    L10n.text("apple.clientworkspacesview.stops_the_process_on_0.7aa0b494", "\($0.name)")
                } ?? L10n.text("apple.clientworkspacesview.stops_the_process_on_the_computer.c5651cd1"))
            }
    }

    /// Whether the waiting host is a headless server, so the waiting card can
    /// offer SSH approval instead of GUI steps. Matched by name: the model's
    /// `awaitingAccessHost` is the display name the card already shows.
    private func isHeadlessHost(named host: String) -> Bool {
        let machines = account.account?.machines ?? []
        let platform = machines.first {
            ($0.label?.isEmpty == false ? $0.label : $0.machineID) == host
        }?.platform
        return isHeadlessPlatform(platform)
    }

    /// A tap on a push. A terminal that needs the person opens here. Chat
    /// is the fallback, over the app because this layout has no sidebar.
    ///
    /// Peek first, consume only once the tap resolves: taking up front and
    /// then failing (host offline, connect busy) lost the tap with no
    /// feedback. A request that never resolves stays pending for the next
    /// tap rather than vanishing.
    private func fulfillNotification() async {
        guard let request = NotificationOpen.shared.request,
              let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return }
        guard let opened = await model.targetFromNotification(request, account: account.account) else {
            // A cancelled attempt is not a failed one. This runs from a
            // `.task`, which the system cancels the moment the view goes
            // away, and `targetFromNotification` answers nil for that too.
            // Acting on it would drop the tap and pull somebody back to
            // Workspaces at the moment they navigated off it.
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
            // Otherwise: not yet, or not ever, and this cannot tell the two
            // apart. Keep the tap for the next attempt until it goes stale,
            // then land on the machine list rather than leave somebody
            // looking at whatever was on screen with nothing to say why.
            if NotificationOpen.shared.dropIfStale() { landAfterFailedTap() }
            return
        }
        // Compare before consuming. `take` always clears, so a newer tap that
        // arrived while this one resolved would be swallowed by the equality
        // check and both would be dropped. Peeking leaves it for its own turn.
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
            // Same thread, phone was just locked: bring that window
            // forward. Presenting again remounts the transcript on top.
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

    /// Where a tap ends up when what it named cannot be found.
    ///
    /// Workspaces, not Home: every notification this app sends is about work
    /// on a machine, so the machine list is both where the tap was heading
    /// and the screen that can say the host is offline. It is also where the
    /// root already sent them on the way in, so this is a landing rather than
    /// a second move.
    private func landAfterFailedTap() {
        if navigation.destination != .workspaces {
            navigation.destination = .workspaces
        }
    }

    /// Turn a folder named without a push into the push this layout uses.
    ///
    /// Setup ends by calling `open(folderID:section:)`, which is all the
    /// sidebar needs: it reads `folderID` for its own detail. The tab stack
    /// has no such read, so the same handoff landed on the host list. Resolve
    /// it once the connected host's folder list contains it, and only once per
    /// value, so a reconnect cannot reopen what somebody just backed out of.
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
        // A chooser already pushed this exact folder. Marking it handled is
        // enough; a second push would stack the same screen twice.
        guard navigation.workspacesPath.last != push else { return }
        navigation.pushFolder(
            peerKey: peer,
            hostName: host.name,
            folder: folder,
            section: navigation.section
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
                onNewChat: { starting = .chat }
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
            ForEach(model.folders) { folder in
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
                    Button(L10n.text("apple.clientworkspacesview.new_terminal.fe544556"), .create) { starting = .sessions }
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
                                pendingClose = session
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

    /// This phone, on the screen that lists the devices it can reach.
    ///
    /// It has no Connect button because a phone cannot dial itself, and it is
    /// never drawn as offline: the app asking the question is running on it.
    @ViewBuilder
    private var thisDeviceRow: some View {
        // Deliberately not a card. The host cards above open a device when
        // tapped, and this row opens nothing, so wearing the same surface
        // taught people it could be entered too.
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
                    .controlSize(.small)
                } else {
                    Button(model.isBusy(with: host.peerKey) ? L10n.text("apple.clientworkspacesview.connecting.72021eb7") : L10n.text("common.connect"), .connect) {
                        Task { await model.connect(host) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(model.isConnecting != nil || model.pendingPeer != nil || host.online == false)
                }
            }
            // Opening the device used to hide behind a bare chevron, so the
            // card never said it could be entered. It says so now, as its own
            // row. The card tap stays for the same action.
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(Theme.accent)
                .foregroundStyle(Theme.accent)
            }
            if model.connectedKey == host.peerKey {
                // What the machine is doing, rather than a sentence saying it
                // is connected. The row already says that: the dot is lit and
                // the button says Disconnect.
                HostStatsStrip(peer: host.peerKey)
                // Per-host, on by default, same line-height as Disconnect.
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
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        // No card-wide tap gesture: the card holds Connect/Disconnect, Open
        // device and an Auto-connect toggle, and a parent `onTapGesture` fires
        // for taps on those controls too, pushing to Devices mid-action. The
        // explicit "Open device" row above is the way in.
    }
}

/// A host device the phone can dial (account machine that is not a client).
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
    private(set) var hosts: [ClientHost] = []
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var sessions: [PtySessionInfo] = []
    private(set) var recentChats: [ChatRecentConversation] = []
    private(set) var connectedKey: String?
    private(set) var isConnecting: String?
    /// An explicitly tapped host waiting for the dial while another attempt
    /// is still running. The row spins on this as well as on `isConnecting`,
    /// and the auto path stays out while it is set, so a tap can never lose
    /// to an auto-connect with nothing on screen saying why.
    private(set) var pendingPeer: String?
    /// The machine somebody picked by hand, until they pick another or
    /// disconnect. It outlives the attempt on purpose: waiting for approval,
    /// a refusal and an error all clear `connectedKey`, which handed the auto
    /// path a free run at the remembered machine while the card for the one
    /// they tapped was still on screen. That is what connected the first tap
    /// on a second machine to the first one.
    private(set) var chosenPeer: String?
    private(set) var errorMessage: String?
    /// What this phone is called. It is never in the host list (it cannot dial
    /// itself), so it gets one line of its own.
    private(set) var thisDeviceName: String?
    /// Full-screen terminal currently shown from the all-sessions list.
    var activeTerminal: ClientTerminalSession?
    @ObservationIgnored private var lastRecoverAt = Date.distantPast

    func refresh(account: Account?) async {
        errorMessage = nil
        let thisID = account?.thisMachineID
        let machines = account?.machines ?? []
        // Who this phone is, from the host rather than from the account. A
        // record registered before the server knew about client machines still
        // carries no kind and would otherwise list this phone as a host that
        // is asleep, which is the one device on the list that certainly is not.
        let identity = try? await Bridge.machineIdentity()
        let selfKey = identity?.key.lowercased()
        thisDeviceName = {
            let label = identity?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return label.isEmpty ? ClientDeviceName.marketing : label
        }()
        hosts = machines.compactMap { machine -> ClientHost? in
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
        if let key = connectedKey {
            await reloadRemote(peerKey: key)
        }
    }

    /// Soft guidance (approve on host), not a hard failure banner.
    private(set) var infoMessage: String?
    /// The computer this device has asked to be let into, while that request
    /// is still standing. Named rather than a bool, because the card says
    /// which machine somebody has to walk to.
    private(set) var awaitingAccessHost: String?
    /// The watch that connects on its own once the answer lands.
    ///
    /// The waiting card shows a picture that keeps moving, and a picture that
    /// keeps moving is a promise that something is still happening. It was not:
    /// somebody who walked over, approved the device and came back found the
    /// same card, with nothing telling them to press Connect again.
    private var accessWatch: Task<Void, Never>?

    /// Explicit, from a tap or a notification. Queues behind an in-flight
    /// dial instead of dropping: dropping is what let an auto-connect steal
    /// the first tap on a cold start, landing the detail column on a machine
    /// nobody asked for. The latest tap wins; a tap on the host already
    /// dialling or already queued is a no-op.
    func connect(_ host: ClientHost) async {
        chosenPeer = host.peerKey
        if isConnecting == host.peerKey || pendingPeer == host.peerKey { return }
        pendingPeer = host.peerKey
        // Wait out the in-flight dial however long its ladder takes. The old
        // fixed twenty-second cap dropped the tap while a dial that had not
        // answered was still running, and a dial can take a minute or more.
        // Nothing else may start while this is queued, so once the field is
        // clear this attempt is the one that dials.
        while !Task.isCancelled, pendingPeer == host.peerKey, isConnecting != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled, isConnecting == nil, pendingPeer == host.peerKey else {
            if pendingPeer == host.peerKey { pendingPeer = nil }
            return
        }
        await dial(host, recovering: false)
    }

    /// The auto path. Never queues and never preempts: while an explicit tap
    /// is waiting or dialling, this drops, so redialling the last host cannot
    /// undo a machine somebody just picked.
    private func autoDial(_ host: ClientHost) async {
        guard isConnecting == nil, pendingPeer == nil else { return }
        await dial(host, recovering: false)
    }

    static func autoConnectKey(for peerKey: String) -> String {
        "client.autoConnectHost.\(peerKey)"
    }

    /// Whether this host may be dialled without being asked.
    ///
    /// Missing means on, and that is the intended default rather than an
    /// oversight: nothing dials on its own until somebody has connected to a
    /// machine by hand once, because the auto path needs
    /// `client.lastConnectedHost` and only a successful connection writes it.
    /// So the switch is an opt out of redialling the machine you were last
    /// on, not an opt in to being dialled.
    static func isAutoConnectEnabled(for peerKey: String) -> Bool {
        UserDefaults.standard.object(forKey: autoConnectKey(for: peerKey)) as? Bool ?? true
    }

    /// The one place that dials without being asked.
    ///
    /// On the model rather than on a screen, because the iPad's sidebar owns
    /// one of these and draws the folder tree from it without ever mounting
    /// `ClientWorkspacesView`. With this on the view, a keyboard iPad opened
    /// to an empty tree and stayed there until somebody tapped Workspaces,
    /// which is the surface that happened to hold the code.
    ///
    /// Several things want it: a screen appearing, the host list changing as
    /// a machine wakes, coming back to the foreground, and now two surfaces
    /// doing each of those. They overlap constantly, and `connectedKey` is
    /// only set once a connection has finished, so callers cannot use it to
    /// tell whether one is already under way. `autoDial` dropping while
    /// anything is under way or queued is what makes the overlap harmless.
    ///
    /// `connectedKey` is in-memory, so a cold start has nothing to recover:
    /// the last peer that was connected is remembered on disk instead.
    func autoConnectLastHost() async {
        guard connectedKey == nil, isConnecting == nil, pendingPeer == nil else { return }
        guard let last = UserDefaults.standard.string(forKey: "client.lastConnectedHost"),
              chosenPeer == nil || chosenPeer == last,
              Self.isAutoConnectEnabled(for: last),
              let host = hosts.first(where: { $0.peerKey == last }),
              host.online != false
        else { return }
        await autoDial(host)
    }

    /// Redial the current host after a path change. Keeps the connected
    /// surface up and retries `no_such_peer` at 1/2/4s instead of pinning
    /// a red error that only a force-quit used to clear.
    func recoverAfterNetworkChange(account: Account?) async {
        // An attempt already running is the recovery. Its ladder outlasts the
        // path change that woke this, so redialling on top of it only refreshes
        // the list twice. A queued explicit tap wins over the recovery too.
        guard isConnecting == nil, pendingPeer == nil else { return }
        let now = Date()
        if now.timeIntervalSince(lastRecoverAt) < 1.5 { return }
        lastRecoverAt = now
        await refresh(account: account)
        guard let key = connectedKey,
              let host = hosts.first(where: { $0.peerKey == key })
        else { return }
        await dial(host, recovering: true)
        activeTerminal?.clearTransientTunnelError()
    }

    /// One attempt at a time, for the whole model.
    ///
    /// `connectedKey` is not set until a connection has finished, so it
    /// cannot stand in for "busy": every caller that checked it was free to
    /// start a second attempt while the first was still on its retry ladder,
    /// and the two would pair, raise a tunnel and load the remote side twice.
    /// `isConnecting` is set for the whole run, including the sleeps, so this
    /// is the check that actually holds. Private: explicit taps enter through
    /// `connect`, which queues, and the auto path through `autoDial`, which
    /// drops. Both end up here, never two at once.
    private func dial(_ host: ClientHost, recovering: Bool) async {
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
        isConnecting = host.peerKey
        defer { isConnecting = nil }
        if !recovering {
            errorMessage = nil
            infoMessage = nil
            // A fresh attempt asks again rather than leaving the old card up,
            // so pressing Connect always means something happened.
            stopWatchingForAccess()
        }
        let delays: [UInt64] = [0, 1, 2, 4]
        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                infoMessage = ClientTunnelCopy.waiting(host.name)
                errorMessage = nil
                try? await Task.sleep(for: .seconds(delay))
            }
            do {
                await ClientDeviceName.publish()
                let peer = try await Bridge.pair(
                    key: host.peerKey,
                    label: host.name,
                    address: ""
                )
                _ = try await Bridge.setTunnel(true)
                // Asked before anything is loaded, and asked *for* rather than
                // reported. Connect used to walk straight into the refusal and
                // show it as a failure with a Try again that could never
                // succeed: there was no way to ask from this screen, only from
                // the device's own page. Pressing Connect is somebody saying
                // they want in, so this asks on their behalf and waits.
                let allowed = try await Bridge.workspaceAccessAllowed(peer: peer.key)
                if !allowed {
                    _ = try? await Bridge.askWorkspaceAccess(peer: host.peerKey)
                    // Its own state, not `infoMessage`. Waiting on a person at
                    // another computer is the one thing on this screen where
                    // nothing will change until they act, and a line of grey
                    // caption is not enough to say so.
                    awaitingAccessHost = host.name
                    infoMessage = nil
                    errorMessage = nil
                    if !recovering {
                        connectedKey = nil
                        folders = []
                        sessions = []
                        recentChats = []
                    }
                    watchForAccess(host)
                    return
                }
                stopWatchingForAccess()
                async let loadedFolders = Bridge.remoteWorkspaces(peer: peer)
                async let loadedSessions = ClientRemote.ptyList(peer: peer.key)
                async let loadedChats = ClientRemote.recentChats(peer: peer.key)
                folders = try await loadedFolders
                sessions = (try? await loadedSessions) ?? []
                recentChats = (try? await loadedChats) ?? []
                connectedKey = host.peerKey
                UserDefaults.standard.set(host.peerKey, forKey: "client.lastConnectedHost")
                errorMessage = nil
                infoMessage = nil
                return
            } catch {
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

    /// Wait for the answer, then connect without being asked again.
    ///
    /// The same cadence the Mac polls its own pending list on. Cheap: one
    /// small call to the host that already answered, and it stops the moment
    /// it succeeds or the screen goes away.
    private func watchForAccess(_ host: ClientHost) {
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            for _ in 0..<ClientAccessWatch.attempts {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: ClientAccessWatch.interval)
                guard !Task.isCancelled, let self else { return }
                // The key is already known, so this asks one small question
                // and nothing else. Re-pairing on every tick would rewrite
                // this device's peer store every five seconds to learn a
                // string it was already holding.
                guard let allowed = try? await Bridge.workspaceAccessAllowed(peer: host.peerKey),
                      allowed
                else { continue }
                guard !Task.isCancelled else { return }
                // Let go of the handle before connecting. The dial stops the
                // watch on its way in, and a task that cancels itself
                // mid-flight would take the retry ladder's own sleeps with it.
                // `autoDial`, not `connect`: the person may have tapped
                // another machine since, and the watch must not queue the old
                // one back up behind it.
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
    }

    /// A row spins while its host is dialling or queued for the dial. One
    /// helper so the sidebar and the host card cannot disagree about it.
    func isBusy(with peerKey: String) -> Bool {
        isConnecting == peerKey || pendingPeer == peerKey
    }

    func disconnect() {
        pendingPeer = nil
        chosenPeer = nil
        stopWatchingForAccess()
        activeTerminal?.stop()
        activeTerminal = nil
        connectedKey = nil
        folders = []
        sessions = []
        recentChats = []
    }

    func openSession(_ info: PtySessionInfo) {
        guard let peer = connectedKey else { return }
        activeTerminal = ClientTerminalSession(peer: peer, info: info)
    }

    func closeSession(_ info: PtySessionInfo) async {
        guard let peer = connectedKey else { return }
        do {
            if activeTerminal?.hostID == info.id {
                try await activeTerminal?.close()
                activeTerminal = nil
            } else {
                try await ClientRemote.ptyClose(peer: peer, id: info.id)
            }
            sessions.removeAll { $0.id == info.id }
        } catch {
            let host = hosts.first { $0.peerKey == peer }?.name
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: host)
        }
    }

    private func reloadRemote(peerKey: String) async {
        guard let peer = try? await Bridge.peers().first(where: { $0.key == peerKey }) else {
            return
        }
        folders = (try? await Bridge.remoteWorkspaces(peer: peer)) ?? folders
        sessions = (try? await ClientRemote.ptyList(peer: peer.key)) ?? sessions
        recentChats = (try? await ClientRemote.recentChats(peer: peer.key)) ?? recentChats
    }

    /// What a notification tap should open on this host.
    enum NotificationTarget {
        case session(PtySessionInfo)
        case chat(peer: String, hostName: String, folder: WorkspaceFolder?, chat: ChatRecentConversation)
    }

    /// Dial the machine the push named, then pick what needs the person.
    ///
    /// A named session always wins. The any-attention fallback applies to
    /// session requests and to pushes naming nothing (a push carries only a
    /// machine id): a chat request must reach its conversation rather than
    /// diverting to an unrelated waiting terminal.
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
