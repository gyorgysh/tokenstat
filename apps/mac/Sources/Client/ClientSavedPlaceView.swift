// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// Reachability belongs to the destination, including when it is opened from
/// somewhere other than Home. Known sleeping machines never start a tunnel.
struct ClientPlaceAvailability<Content: View>: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    let peer: String
    let hostName: String
    @ViewBuilder let content: () -> Content

    private var machine: Machine? {
        account.account?.machines.first { $0.publicIdentity == peer }
    }

    private var availability: WorkDestinationResolver.Availability {
        WorkDestinationResolver.availability(.init(
            accountVerified: account.signedIn,
            hostLinked: machine != nil,
            connected: !connectivity.isOffline && machine?.online != false
        ))
    }

    var body: some View {
        Group {
            switch availability {
            case .live:
                content()
            case .hostRemoved:
                ClientEmptyState(
                    kind: .unreachable, title: L10n.text("apple.clientsavedplaceview.this_machine_is_no_longer_linked.b502d162"),
                    message: L10n.text("apple.clientsavedplaceview.you_can_find_the_machines_on_your_account.4c403c3f")
                )
                .padding(Theme.Space.m)
            case .accessRequired:
                ClientEmptyState(
                    kind: .unreachable, title: L10n.text("apple.clientsavedplaceview.verify_your_account.5f06da5b"),
                    message: L10n.text("apple.clientsavedplaceview.verify_your_account_before_returning_to_th.2329f791")
                )
                .padding(Theme.Space.m)
            default:
                ClientEmptyState(
                    kind: .unreachable,
                    title: connectivity.isOffline ? L10n.text("apple.clientsavedplaceview.you_are_offline.4d5c9439") : L10n.text("apple.clientsavedplaceview.0_is_asleep.99e9fc66", "\(hostName)"),
                    message: connectivity.isOffline
                        ? L10n.text("apple.clientsavedplaceview.your_place_is_saved_connect_to_the_interne.1b3085ea")
                        : L10n.text("apple.clientsavedplaceview.your_place_is_saved_when_this_machine_is_a.833d1aae"),
                    actionTitle: connectivity.isOffline ? nil : L10n.text("apple.clientsavedplaceview.check_again.fb7099ad"),
                    actionIcon: .refresh,
                    action: connectivity.isOffline ? nil : { Task { await account.load() } }
                )
                .padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
    }
}

/// Resolves IDs only after navigation. Paths and terminal commands come from
/// the peer here, never from the saved history or Home.
struct ClientSavedPlaceView: View {
    let place: ClientRecentPlaces.Place
    var restoredSection: WorkspaceSection? = nil
    var onRestoredTerminalClose: (() -> Void)? = nil
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    @State private var folder: WorkspaceFolder?
    @State private var terminal: ClientTerminalSession?
    @State private var error: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var visible = false
    @State private var loadGeneration: UInt64 = 0
    @State private var loadedPlaceID: ClientRecentPlaces.Place.ID?
    @State private var showTerminal = false
    @State private var needsAccess = false

    private var hostName: String {
        account.account?.machines.first { $0.publicIdentity == place.id.peer }?.displayName ?? L10n.text("apple.clientsavedplaceview.machine.8f1cc42d")
    }

    var body: some View {
        Group {
            if place.id.kind == .chat,
               let workspace = place.id.workspaceID, let chat = place.id.itemID {
                ClientRecentChatView(peer: place.id.peer, workspaceID: workspace,
                                     folderName: place.workspaceName, hostName: hostName, chatID: chat)
            } else {
                ClientPlaceAvailability(peer: place.id.peer, hostName: hostName) {
                    destination
                        .task {
                            visible = true
                            await load()
                        }
                        .onDisappear {
                            visible = false
                            loadGeneration &+= 1
                            loading = false
                        }
                }
            }
        }
        .navigationTitle(folder?.name ?? place.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showTerminal) {
            if let terminal { ClientTerminalScreen(session: terminal, hostName: hostName) }
        }
    }

    @ViewBuilder private var destination: some View {
        if let error {
            ClientErrorCard(message: error) { retry() }
                .padding(Theme.Space.m)
        } else if needsAccess {
            ClientHostWorkspacesView(peerKey: place.id.peer, hostName: hostName)
        } else if let folder {
            if let restoredSection {
                ClientWorkspaceSectionDetail(peer: place.id.peer, hostName: hostName,
                    folder: folder, section: restoredSection)
            } else {
                ClientWorkspaceDetailView(peer: place.id.peer, hostName: hostName, folder: folder)
            }
        } else if let terminal, let onRestoredTerminalClose {
            ClientTerminalScreen(session: terminal, hostName: hostName, onClose: onRestoredTerminalClose)
        } else if loaded {
            ClientEmptyState(
                kind: .nothingYet,
                title: terminal == nil ? L10n.text("apple.clientsavedplaceview.this_terminal_has_ended.0a28dfb5") : L10n.text("apple.clientsavedplaceview.terminal.e0926fda"),
                message: terminal == nil ? L10n.text("apple.clientsavedplaceview.the_session_is_no_longer_running_on_0.12e3f3d6", "\(hostName)") : L10n.text("apple.clientsavedplaceview.return_to_your_session_on_0.df4dfa21", "\(hostName)"),
                actionTitle: terminal == nil ? nil : L10n.text("apple.clientsavedplaceview.open_terminal.acb1f43d"),
                actionIcon: .reopen,
                action: terminal == nil ? nil : { retry(reopen: true) }
            )
            .padding(Theme.Space.m)
        } else {
            ClientWireframe.Rows(count: 3).padding(Theme.Space.m)
        }
    }

    private func retry(reopen: Bool = false) {
        let generation = loadGeneration
        Task {
            guard visible, generation == loadGeneration else { return }
            await load(reopen: reopen)
        }
    }

    private func load(reopen: Bool = false) async {
        // Once per place: availability rebuilds recreate `destination` and its
        // `.task`, and without this each rebuild re-pairs and re-raises the
        // tunnel while the person sits on the screen.
        // An explicit reopen must fetch the existing session again: dismissal
        // stopped the previous attachment, which cannot be reused.
        guard visible, !loading, reopen || loadedPlaceID != place.id,
              let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return }
        let generation = loadGeneration
        func stillCurrent() -> Bool {
            visible && generation == loadGeneration && !Task.isCancelled
                && !connectivity.isOffline && WorkSessionContext.shared.scope == scope
                && account.account?.machines.contains {
                    $0.publicIdentity == place.id.peer && $0.online != false
                } == true
        }
        guard stillCurrent() else { return }
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        error = nil
        do {
            // Home has never needed a tunnel. A cold-start tap must establish
            // one here, just as opening the host from Devices does.
            await ClientDeviceName.publish()
            guard stillCurrent() else { return }
            _ = try await Bridge.pair(key: place.id.peer, label: hostName, address: "")
            guard stillCurrent() else { return }
            _ = try await Bridge.setTunnel(true)
            guard stillCurrent() else { return }
            let allowed = try await Bridge.workspaceAccessAllowed(peer: place.id.peer)
            guard stillCurrent() else { return }
            guard allowed else {
                needsAccess = true
                loadedPlaceID = place.id
                return
            }
            if place.id.kind == .workspace, let workspace = place.id.workspaceID {
                var value = try await ClientRemote.status(peer: place.id.peer, workspace: workspace)
                guard stillCurrent() else { return }
                value.id = "remote:\(place.id.peer):\(workspace)"
                value.machineID = place.id.peer
                folder = value
            } else if place.id.kind == .terminal, let id = place.id.itemID {
                let sessions = try await ClientRemote.ptyList(peer: place.id.peer)
                guard stillCurrent() else { return }
                // Finished sessions retain output on the host. A completed
                // Live Activity should still open that exact terminal for review.
                if let info = sessions.first(where: { $0.id == id && $0.hidden != true }) {
                    terminal = ClientTerminalSession(peer: place.id.peer, info: info)
                    showTerminal = onRestoredTerminalClose == nil
                } else {
                    terminal = nil
                }
            }
            loaded = true
            loadedPlaceID = place.id
        } catch {
            guard stillCurrent() else { return }
            self.error = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }
}
#endif
