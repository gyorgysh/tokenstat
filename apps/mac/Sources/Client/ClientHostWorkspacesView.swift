// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// One host's folders and running sessions, opened from that device's page.
///
/// The Workspaces tab is the same machine plane reached the other way round:
/// pick a host, then a folder. Somebody who arrived at a device from the
/// account list is already holding the answer to "which machine", so this
/// screen dials it on appearance instead of asking again.
struct ClientHostWorkspacesView: View {
    let peerKey: String
    let hostName: String
    @State private var model = ClientHostWorkspacesModel()

    var body: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // What the machine is doing, at the top of the screen that
                // opens it. This used to exist only on the Devices page, so the
                // two things people most want from another computer were behind
                // a tab nobody visits for that reason.
                ClientHostHeader(
                    name: hostName,
                    peerKey: peerKey,
                    // Unknown until a call has actually come back. Reporting
                    // awake while the first connect is still in flight told
                    // somebody a sleeping computer was up for as long as the
                    // attempt took to fail.
                    online: model.reachedHost,
                    showsOpenWork: false
                )

                if let message = model.errorMessage {
                    ClientErrorCard(message: message) {
                        Task { await model.connect(peerKey: peerKey, name: hostName) }
                    }
                }

                if model.isConnecting {
                    ClientWireframe.Rows(count: 3)
                } else if model.isAllowed == false {
                    // Not an error. Every device on an account used to reach
                    // every machine on it the moment it signed in; now each one
                    // is let in by name, and this is the screen a device sees
                    // until somebody says yes.
                    VStack(spacing: Theme.Space.s) {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: "\(hostName) has not let this device in yet",
                            message: "Folders, files, terminals and the agents running in them are only open to devices that computer has allowed. This screen opens on its own once the request is answered.",
                            actionTitle: model.isRequesting ? "Asking…" : "Request access",
                            actionIcon: .approve,
                            action: { Task { await model.requestAccess(peerKey: peerKey) } },
                            art: .workspaceAccess
                        )
                        if let notice = model.requestNotice {
                            Text(notice)
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else if model.folders.isEmpty, model.sessions.isEmpty {
                    ClientEmptyState(
                        kind: model.errorMessage == nil ? .nothingYet : .unreachable,
                        title: model.errorMessage == nil
                            ? "No folders on \(hostName) yet"
                            : "Could not reach \(hostName)",
                        message: model.errorMessage == nil
                            ? "Folders added on that computer show up here."
                            : "It has to be awake, with remote reach turned on.",
                        actionTitle: "Try again",
                        actionIcon: .refresh,
                        action: { Task { await model.connect(peerKey: peerKey, name: hostName) } }
                    )
                }

                ClientRecentChatsSection(
                    peer: peerKey,
                    hostName: hostName,
                    folders: model.folders,
                    chats: model.recentChats
                )

                if !model.folders.isEmpty {
                    ClientSectionTitle(title: "Folders", mark: "mark_archive")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                    ForEach(model.folders) { folder in
                        NavigationLink {
                            ClientWorkspaceDetailView(
                                peer: peerKey,
                                hostName: hostName,
                                folder: folder
                            )
                        } label: {
                            ClientFolderRow(folder: folder)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !model.sessions.isEmpty {
                    ClientSectionTitle(title: "Sessions", mark: "mark_terminal")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .padding(.top, Theme.Space.s)
                    ForEach(model.sessions) { session in
                        Button {
                            model.open(session, peer: peerKey)
                        } label: {
                            ClientSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ClientSecurityCard(peerKey: peerKey, peerName: hostName)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(hostName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("host-\(peerKey)") {
                await model.connect(peerKey: peerKey, name: hostName)
            }
        }
        .task { await model.connect(peerKey: peerKey, name: hostName) }
        .fullScreenCover(item: $model.activeTerminal) { session in
            ClientTerminalScreen(
                session: session,
                onClose: { model.activeTerminal = nil }
            )
        }
    }

}

@Observable
@MainActor
final class ClientHostWorkspacesModel {
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var sessions: [PtySessionInfo] = []
    private(set) var recentChats: [ChatConversation] = []
    private(set) var errorMessage: String?
    private(set) var isConnecting = false
    /// Whether a call to this host has come back. Nil until one has, so the
    /// header can say "not known yet" rather than guessing awake.
    private(set) var reachedHost: Bool?
    /// Whether that computer has let this device open its work. Nil until the
    /// question has been asked once, so the screen does not flash a refusal at
    /// somebody who is simply still connecting.
    private(set) var isAllowed: Bool?
    /// What came back from asking, kept apart from `errorMessage`.
    private(set) var requestNotice: String?
    private(set) var isRequesting = false
    /// The watch that reloads on its own once the answer lands, so somebody
    /// who walks over, approves and comes back is not looking at the same
    /// refusal with no sign that anything changed.
    private var accessWatch: Task<Void, Never>?
    var activeTerminal: ClientTerminalSession?

    func connect(peerKey: String, name: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        accessWatch?.cancel()
        accessWatch = nil
        errorMessage = nil
        do {
            await ClientDeviceName.publish()
            let peer = try await Bridge.pair(key: peerKey, label: name, address: "")
            _ = try await Bridge.setTunnel(true)
            // Asked before anything is loaded. Being paired is not being let
            // in: that computer allows each device to open its work
            // explicitly, and a device that has not been allowed should get
            // the screen that says so rather than a list that fails.
            let allowed = try await Bridge.workspaceAccessAllowed(peer: peer.key)
            isAllowed = allowed
            reachedHost = true
            guard allowed else {
                folders = []
                sessions = []
                recentChats = []
                // Opening this screen is somebody saying they want in, so the
                // asking happens without a second press. The button stays, for
                // asking again once a request has gone stale.
                if requestNotice == nil {
                    await requestAccess(peerKey: peerKey)
                }
                watchForAccess(peerKey: peerKey, name: name)
                return
            }
            async let loadedFolders = Bridge.remoteWorkspaces(peer: peer)
            async let loadedSessions = ClientRemote.ptyList(peer: peer.key)
            async let loadedChats = ClientRemote.recentChats(peer: peer.key)
            folders = try await loadedFolders
            sessions = (try? await loadedSessions) ?? []
            recentChats = (try? await loadedChats) ?? []
        } catch {
            errorMessage = error.localizedDescription
            folders = []
            sessions = []
            recentChats = []
            reachedHost = false
            // Unknown again, not refused. A host that could not be reached
            // this time must not be described as having turned this device
            // away: those are different screens with different answers.
            isAllowed = nil
        }
    }

    /// Ask that computer to let this device in.
    ///
    /// The answer is kept apart from `errorMessage`, which is why the screen
    /// could not be loaded. An outcome written into a field something else
    /// reads is how a message ends up changing a state nobody meant it to.
    func requestAccess(peerKey: String) async {
        isRequesting = true
        defer { isRequesting = false }
        do {
            let answer = try await Bridge.askWorkspaceAccess(peer: peerKey)
            if answer.granted == true {
                requestNotice = "This device already has access. Pull to refresh."
            } else {
                requestNotice = "Asked. Approve this device on that computer."
            }
        } catch {
            requestNotice = error.localizedDescription
        }
    }

    /// Poll for the answer, then load. Stops as soon as it succeeds.
    private func watchForAccess(peerKey: String, name: String) {
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            for _ in 0..<ClientAccessWatch.attempts {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: ClientAccessWatch.interval)
                guard !Task.isCancelled, let self else { return }
                guard let allowed = try? await Bridge.workspaceAccessAllowed(peer: peerKey),
                      allowed
                else { continue }
                guard !Task.isCancelled else { return }
                // Released before reconnecting, for the reason `connect` gives.
                self.accessWatch = nil
                await self.connect(peerKey: peerKey, name: name)
                return
            }
        }
    }

    func open(_ info: PtySessionInfo, peer: String) {
        activeTerminal = ClientTerminalSession(peer: peer, info: info)
    }
}

#endif
