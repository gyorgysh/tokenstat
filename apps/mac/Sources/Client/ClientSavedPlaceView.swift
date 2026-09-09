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

    var body: some View {
        Group {
            if connectivity.isOffline || machine?.online == false {
                ClientEmptyState(
                    kind: .unreachable,
                    title: connectivity.isOffline ? "You are offline" : "\(hostName) is asleep",
                    message: connectivity.isOffline
                        ? "Your place is saved. Connect to the internet to pick it up again."
                        : "Your place is saved. When this machine is awake and running tokenstat, you can return here.",
                    actionTitle: connectivity.isOffline ? nil : "Check again",
                    actionIcon: .refresh,
                    action: connectivity.isOffline ? nil : { Task { await account.load() } }
                )
                .padding(Theme.Space.m)
            } else if account.account != nil && machine == nil {
                ClientEmptyState(
                    kind: .unreachable, title: "This machine is no longer linked",
                    message: "You can find the machines on your account in Devices."
                )
                .padding(Theme.Space.m)
            } else {
                content()
            }
        }
        .background(Theme.background)
    }
}

/// Resolves IDs only after navigation. Paths and terminal commands come from
/// the peer here, never from the saved history or Home.
struct ClientSavedPlaceView: View {
    let place: ClientRecentPlaces.Place
    @Environment(AccountModel.self) private var account
    @State private var folder: WorkspaceFolder?
    @State private var terminal: ClientTerminalSession?
    @State private var error: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var loadedPlaceID: ClientRecentPlaces.Place.ID?
    @State private var showTerminal = false
    @State private var needsAccess = false

    private var hostName: String {
        account.account?.machines.first { $0.publicIdentity == place.id.peer }?.displayName ?? "Machine"
    }

    var body: some View {
        Group {
            if place.id.kind == .chat,
               let workspace = place.id.workspaceID, let chat = place.id.itemID {
                ClientRecentChatView(peer: place.id.peer, workspaceID: workspace,
                                     folderName: place.workspaceName, hostName: hostName, chatID: chat)
            } else {
                ClientPlaceAvailability(peer: place.id.peer, hostName: hostName) {
                    destination.task { await load() }
                }
            }
        }
        .navigationTitle(place.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showTerminal) {
            if let terminal { ClientTerminalScreen(session: terminal, hostName: hostName) }
        }
    }

    @ViewBuilder private var destination: some View {
        if let error {
            ClientErrorCard(message: error) { Task { await load() } }
                .padding(Theme.Space.m)
        } else if needsAccess {
            ClientHostWorkspacesView(peerKey: place.id.peer, hostName: hostName)
        } else if let folder {
            ClientWorkspaceDetailView(peer: place.id.peer, hostName: hostName, folder: folder)
        } else if loaded {
            ClientEmptyState(
                kind: .nothingYet,
                title: terminal == nil ? "This terminal has ended" : "Terminal",
                message: terminal == nil ? "The session is no longer running on \(hostName)." : "Return to your session on \(hostName).",
                actionTitle: terminal == nil ? nil : "Open terminal",
                actionIcon: .reopen,
                action: terminal == nil ? nil : { Task { await load() } }
            )
            .padding(Theme.Space.m)
        } else {
            ClientWireframe.Rows(count: 3).padding(Theme.Space.m)
        }
    }

    private func load() async {
        // Once per place: availability rebuilds recreate `destination` and its
        // `.task`, and without this each rebuild re-pairs and re-raises the
        // tunnel while the person sits on the screen.
        guard !loading, loadedPlaceID != place.id else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            // Home has never needed a tunnel. A cold-start tap must establish
            // one here, just as opening the host from Devices does.
            await ClientDeviceName.publish()
            _ = try await Bridge.pair(key: place.id.peer, label: hostName, address: "")
            _ = try await Bridge.setTunnel(true)
            guard try await Bridge.workspaceAccessAllowed(peer: place.id.peer) else {
                needsAccess = true
                loadedPlaceID = place.id
                return
            }
            if place.id.kind == .workspace, let workspace = place.id.workspaceID {
                var value = try await ClientRemote.status(peer: place.id.peer, workspace: workspace)
                value.id = "remote:\(place.id.peer):\(workspace)"
                value.machineID = place.id.peer
                folder = value
            } else if place.id.kind == .terminal, let id = place.id.itemID {
                let sessions = try await ClientRemote.ptyList(peer: place.id.peer)
                if let info = sessions.first(where: { $0.id == id && $0.alive }) {
                    terminal = ClientTerminalSession(peer: place.id.peer, info: info)
                    showTerminal = true
                } else {
                    terminal = nil
                }
            }
            loaded = true
            loadedPlaceID = place.id
        } catch {
            self.error = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }
}
#endif
