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
    @MainActor
    init(model: ClientWorkspacesModel? = nil) {
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
                        ClientAwaitingAccessCard(hostName: host)
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
                            title: "Remote is on Patron",
                            message: "This phone already shares the account and sees the usage "
                                + "from every device on it. Opening folders and terminals on "
                                + "the computer is a paid feature.",
                            actionTitle: "See plans",
                            actionIcon: .plans,
                            action: {
                                store.showPaywall = true
                            }
                        )
                    } else if model.hosts.isEmpty {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: "No host devices yet",
                            message: "Install tokenstat on a computer, turn on Reach devices "
                                + "from anywhere, and sign in. Hosts appear here so this phone "
                                + "can open their folders and sessions.",
                            mark: "mark_host"
                        )
                    } else {
                        ClientSectionTitle(title: "Hosts on your account", mark: "mark_host")
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
                            ClientRecentChatsSection(
                                peer: peer,
                                hostName: host.name,
                                folders: model.folders,
                                chats: model.recentChats
                            )
                        }

                        if !model.sessions.isEmpty {
                            Text("All sessions")
                                .font(ClientType.sectionTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                                .padding(.top, Theme.Space.s)
                            List {
                                ForEach(model.sessions) { session in
                                    Button {
                                        model.openSession(session)
                                    } label: {
                                        ClientSessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Theme.Space.s, trailing: 0))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button("Close", role: .destructive) {
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

                        if !model.folders.isEmpty {
                            ClientSectionTitle(title: "Folders", mark: "mark_archive")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                                .padding(.top, Theme.Space.s)
                            ForEach(model.folders) { folder in
                                NavigationLink {
                                    if let peer = model.connectedKey,
                                       let host = model.hosts.first(where: { $0.peerKey == peer })
                                    {
                                        ClientWorkspaceDetailView(
                                            peer: peer,
                                            hostName: host.name,
                                            folder: folder
                                        )
                                    }
                                } label: {
                                    ClientFolderRow(folder: folder)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, 96)
            }
            .background(Theme.background)
            .navigationTitle("Workspaces")
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
            }
            // When the host list refreshes and the last host comes online
            // after being offline (Mac wakes, lid opens), try again. This is
            // what makes "keep trying until online" work without a timer.
            .onChange(of: model.hosts) { _, _ in
                Task { await model.autoConnectLastHost() }
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
                "Close this session?",
                isPresented: Binding(
                    get: { pendingClose != nil },
                    set: { if !$0 { pendingClose = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Close", role: .destructive) {
                    if let session = pendingClose {
                        Task { await model.closeSession(session) }
                    }
                    pendingClose = nil
                }
                Button("Keep it", role: .cancel) { pendingClose = nil }
            } message: {
                Text(model.hosts.first { $0.peerKey == model.connectedKey }.map {
                    "Stops the process on \($0.name)."
                } ?? "Stops the process on the computer.")
            }
    }

    /// This phone, on the screen that lists the devices it can reach.
    ///
    /// It has no Connect button because a phone cannot dial itself, and it is
    /// never drawn as offline: the app asking the question is running on it.
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
                    Text("This device")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Online")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
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
                    Text("Offline")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else if model.connectedKey == host.peerKey {
                    Button("Disconnect", .disconnect) {
                        model.disconnect()
                    }
                    .font(ClientType.caption.weight(.semibold))
                } else {
                    Button(model.isConnecting == host.peerKey ? "Connecting…" : "Connect", .connect) {
                        Task { await model.connect(host) }
                    }
                    .font(ClientType.caption.weight(.semibold))
                    .disabled(model.isConnecting != nil || host.online == false)
                }
                // Inline, after the button. As a bottom-trailing overlay this
                // landed on top of Connect whenever the card was a single row,
                // which is every card that is not the connected one.
                if host.machineID != nil {
                    Image(systemName: "chevron.right")
                        .font(ClientType.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            if model.connectedKey == host.peerKey {
                // What the machine is doing, rather than a sentence saying it
                // is connected. The row already says that: the dot is lit and
                // the button says Disconnect.
                HostStatsStrip(peer: host.peerKey)
                // Per-host, on by default, same line-height as Disconnect.
                HStack(spacing: 6) {
                    Text("Auto-connect")
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
                .accessibilityLabel("Auto-connect \(host.name)")
                .accessibilityValue(isAutoConnectEnabled(for: host.peerKey) ? "On" : "Off")
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        // The whole card, minus the button, opens that machine on Devices.
        // `contentShape` so the padding is part of the target, and a plain
        // background gesture rather than a `NavigationLink` because Connect
        // and Disconnect live inside this card and a link would swallow them.
        .contentShape(Rectangle())
        .onTapGesture { navigation.openDevice(machineID: host.machineID) }
        .accessibilityAction(named: "Show this device") {
            navigation.openDevice(machineID: host.machineID)
        }
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
                return "Host"
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

    func connect(_ host: ClientHost) async {
        await connect(host, recovering: false)
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
    /// tell whether one is already under way. `connect` refusing while
    /// `isConnecting` is set is what makes the overlap harmless.
    ///
    /// `connectedKey` is in-memory, so a cold start has nothing to recover:
    /// the last peer that was connected is remembered on disk instead.
    func autoConnectLastHost() async {
        guard connectedKey == nil, isConnecting == nil else { return }
        guard let last = UserDefaults.standard.string(forKey: "client.lastConnectedHost"),
              Self.isAutoConnectEnabled(for: last),
              let host = hosts.first(where: { $0.peerKey == last }),
              host.online != false
        else { return }
        await connect(host)
    }

    /// Redial the current host after a path change. Keeps the connected
    /// surface up and retries `no_such_peer` at 1/2/4s instead of pinning
    /// a red error that only a force-quit used to clear.
    func recoverAfterNetworkChange(account: Account?) async {
        // An attempt already running is the recovery. Its ladder outlasts the
        // path change that woke this, so redialling on top of it only refreshes
        // the list twice.
        guard isConnecting == nil else { return }
        let now = Date()
        if now.timeIntervalSince(lastRecoverAt) < 1.5 { return }
        lastRecoverAt = now
        await refresh(account: account)
        guard let key = connectedKey,
              let host = hosts.first(where: { $0.peerKey == key })
        else { return }
        await connect(host, recovering: true)
        activeTerminal?.clearTransientTunnelError()
    }

    /// One attempt at a time, for the whole model.
    ///
    /// `connectedKey` is not set until a connection has finished, so it
    /// cannot stand in for "busy": every caller that checked it was free to
    /// start a second attempt while the first was still on its retry ladder,
    /// and the two would pair, raise a tunnel and load the remote side twice.
    /// `isConnecting` is set for the whole run, including the sleeps, so this
    /// is the check that actually holds.
    func connect(_ host: ClientHost, recovering: Bool) async {
        guard isConnecting == nil else { return }
        guard host.online != false else {
            errorMessage = "\(host.name) is asleep."
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
                    infoMessage = "Approve this phone on \(host.name): open Machines "
                        + "and tap Approve next to this device. Then Connect again."
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
                // Let go of the handle before connecting. `connect` stops the
                // watch on its way in, and a task that cancels itself
                // mid-flight would take the retry ladder's own sleeps with it.
                self.accessWatch = nil
                await self.connect(host)
                return
            }
        }
    }

    private func stopWatchingForAccess() {
        accessWatch?.cancel()
        accessWatch = nil
        awaitingAccessHost = nil
    }

    func disconnect() {
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
}

#endif
