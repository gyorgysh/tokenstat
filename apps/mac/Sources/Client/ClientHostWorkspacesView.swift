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
                if let message = model.errorMessage {
                    ClientErrorCard(message: message) {
                        Task { await model.connect(peerKey: peerKey, name: hostName) }
                    }
                }

                if model.isConnecting {
                    ClientWireframe.Rows(count: 3)
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
                        action: { Task { await model.connect(peerKey: peerKey, name: hostName) } }
                    )
                }

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
                            row(title: folder.name, subtitle: folder.path, symbol: "folder")
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
                            row(
                                title: URL(fileURLWithPath: session.command).lastPathComponent,
                                subtitle: session.alive ? "Running · \(session.cwd)" : "Stopped",
                                symbol: "terminal"
                            )
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

    private func row(title: String, subtitle: String, symbol: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

@Observable
@MainActor
final class ClientHostWorkspacesModel {
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var sessions: [PtySessionInfo] = []
    private(set) var errorMessage: String?
    private(set) var isConnecting = false
    var activeTerminal: ClientTerminalSession?

    func connect(peerKey: String, name: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        errorMessage = nil
        do {
            await ClientDeviceName.publish()
            let peer = try await Bridge.pair(key: peerKey, label: name, address: "")
            _ = try await Bridge.setTunnel(true)
            folders = try await Bridge.remoteWorkspaces(peer: peer)
            sessions = (try? await ClientRemote.ptyList(peer: peer.key)) ?? []
        } catch {
            errorMessage = error.localizedDescription
            folders = []
            sessions = []
        }
    }

    func open(_ info: PtySessionInfo, peer: String) {
        activeTerminal = ClientTerminalSession(peer: peer, info: info)
    }
}

#endif
