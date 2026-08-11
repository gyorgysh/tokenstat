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
    @State private var model = ClientWorkspacesModel()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        Text(message)
                            .font(ClientType.body)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                            .cardSurface()
                    }

                    if model.hosts.isEmpty {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: "No host devices yet",
                            message: "Install tokenstat on a computer, turn on Reach devices "
                                + "from anywhere, and sign in. Hosts appear here so this phone "
                                + "can open their folders and sessions."
                        )
                    } else {
                        Text("Hosts on your account")
                            .font(ClientType.sectionTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)

                        ForEach(model.hosts) { host in
                            hostCard(host)
                        }
                    }

                    if model.connectedKey != nil {
                        if !model.folders.isEmpty {
                            Text("Folders")
                                .font(ClientType.sectionTitle)
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
                                    folderRow(folder)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !model.sessions.isEmpty {
                            Text("All sessions")
                                .font(ClientType.sectionTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                                .padding(.top, Theme.Space.s)
                            ForEach(model.sessions) { session in
                                Button {
                                    model.openSession(session)
                                } label: {
                                    sessionRow(session)
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
            .refreshable { await model.refresh(account: account.account) }
            .task {
                await model.refresh(account: account.account)
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
                Task { await model.refresh(account: account.account) }
            }
            .fullScreenCover(item: $model.activeTerminal) { session in
                ClientTerminalScreen(session: session) {
                    model.activeTerminal = nil
                }
            }
        }
    }

    private func hostCard(_ host: ClientHost) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Circle()
                    .fill(host.online == true ? Theme.accent : Color.secondary.opacity(0.35))
                    .frame(width: 9, height: 9)
                Text(host.name)
                    .font(ClientType.label.weight(.medium))
                Spacer()
                if host.online == false {
                    Text("Offline")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else if model.connectedKey == host.peerKey {
                    Button("Disconnect") {
                        model.disconnect()
                    }
                    .font(ClientType.caption.weight(.semibold))
                } else {
                    Button(model.isConnecting == host.peerKey ? "Connecting…" : "Connect") {
                        Task { await model.connect(host) }
                    }
                    .font(ClientType.caption.weight(.semibold))
                    .disabled(model.isConnecting != nil || host.online == false)
                }
            }
            if model.connectedKey == host.peerKey {
                Text("Connected. Tap a folder for sessions, files and ports.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func folderRow(_ folder: WorkspaceFolder) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                Text(folder.path)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = folder.subtitle {
                    Text(subtitle)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func sessionRow(_ session: PtySessionInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: session.command).lastPathComponent)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.alive ? "Running · \(session.cwd)" : "Stopped")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "terminal")
                .foregroundStyle(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
    private(set) var connectedKey: String?
    private(set) var isConnecting: String?
    private(set) var errorMessage: String?
    /// Full-screen terminal currently shown from the all-sessions list.
    var activeTerminal: ClientTerminalSession?

    func refresh(account: Account?) async {
        errorMessage = nil
        let thisID = account?.thisMachineID
        let machines = account?.machines ?? []
        hosts = machines.compactMap { machine -> ClientHost? in
            guard machine.isHost else { return nil }
            if let thisID, let mid = machine.machineID, mid == thisID { return nil }
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

    func connect(_ host: ClientHost) async {
        guard host.online != false else {
            errorMessage = "\(host.name) is offline."
            return
        }
        isConnecting = host.peerKey
        defer { isConnecting = nil }
        do {
            let peer = try await Bridge.pair(
                key: host.peerKey,
                label: host.name,
                address: ""
            )
            _ = try await Bridge.setTunnel(true)
            folders = try await Bridge.remoteWorkspaces(peer: peer)
            sessions = (try? await ClientRemote.ptyList(peer: peer.key)) ?? []
            connectedKey = host.peerKey
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            connectedKey = nil
            folders = []
            sessions = []
        }
    }

    func disconnect() {
        activeTerminal?.stop()
        activeTerminal = nil
        connectedKey = nil
        folders = []
        sessions = []
    }

    func openSession(_ info: PtySessionInfo) {
        guard let peer = connectedKey else { return }
        activeTerminal = ClientTerminalSession(peer: peer, info: info)
    }

    private func reloadRemote(peerKey: String) async {
        guard let peer = try? await Bridge.peers().first(where: { $0.key == peerKey }) else {
            return
        }
        folders = (try? await Bridge.remoteWorkspaces(peer: peer)) ?? folders
        sessions = (try? await ClientRemote.ptyList(peer: peer.key)) ?? sessions
    }
}

#endif
