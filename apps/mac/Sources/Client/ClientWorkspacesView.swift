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
                        ClientErrorCard(message: message) {
                            Task { await model.refresh(account: account.account) }
                        }
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

                    thisDeviceRow

                    // What the connection is, on the screen that makes them.
                    ClientSecurityCard(
                        peerKey: model.connectedKey,
                        peerName: model.hosts.first { $0.peerKey == model.connectedKey }?.name
                    )

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
            .refreshable {
                ClientRefresh.began()
                await model.refresh(account: account.account)
            }
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
                Image(systemName: "iphone")
                    .foregroundStyle(.secondary)
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
    /// What this phone is called. It is never in the host list (it cannot dial
    /// itself), so it gets one line of its own.
    private(set) var thisDeviceName: String?
    /// Full-screen terminal currently shown from the all-sessions list.
    var activeTerminal: ClientTerminalSession?

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

    func connect(_ host: ClientHost) async {
        guard host.online != false else {
            errorMessage = "\(host.name) is offline."
            infoMessage = nil
            return
        }
        isConnecting = host.peerKey
        defer { isConnecting = nil }
        errorMessage = nil
        infoMessage = nil
        do {
            // Make sure the host sees a named device and not "iPhone", even if
            // the naming at launch happened before this phone had a host.
            await ClientDeviceName.publish()
            let peer = try await Bridge.pair(
                key: host.peerKey,
                label: host.name,
                address: ""
            )
            // Keep the tunnel up: reconnect supervisor owns the socket.
            _ = try await Bridge.setTunnel(true)
            folders = try await Bridge.remoteWorkspaces(peer: peer)
            sessions = (try? await ClientRemote.ptyList(peer: peer.key)) ?? []
            connectedKey = host.peerKey
            errorMessage = nil
            infoMessage = nil
        } catch {
            let text = error.localizedDescription
            if Self.isApprovalNeeded(text) {
                // Same-account auto-approve should cover most cases; if the
                // host is offline from the directory or older, guide the user.
                infoMessage = "Approve this phone on \(host.name): open Machines "
                    + "and tap Approve next to this device. Then Connect again."
                errorMessage = nil
            } else {
                errorMessage = text
            }
            connectedKey = nil
            folders = []
            sessions = []
        }
    }

    private static func isApprovalNeeded(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not approved")
            || lower.contains("waiting for someone to allow")
            || lower.contains("not_approved")
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
