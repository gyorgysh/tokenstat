// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientHostWorkspacesView: View {
    let peerKey: String
    let hostName: String
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @State private var model = ClientHostWorkspacesModel()
    @State private var starting: WorkspaceSection?
    @State private var search = ""
    @State private var customizing = false
    @State private var layout = WorkspacesLayout.shared
    @State private var showApproval = false

    @State private var isHeadless = false

    private var accountPlatform: String? {
        (account.account?.machines ?? [])
            .first { $0.publicIdentity?.caseInsensitiveCompare(peerKey) == .orderedSame }?
            .platform
    }

    private var showsHeadlessInstructions: Bool {
        isHeadless || isHeadlessPlatform(accountPlatform) || isHeadlessPlatform(hostName)
    }

    var body: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ClientHostHeader(
                    name: hostName,
                    peerKey: peerKey,
                    online: model.reachedHost,
                    showsOpenWork: false
                )

                if let message = model.errorMessage,
                   !model.folders.isEmpty || !model.sessions.isEmpty {
                    ClientErrorCard(message: message) {
                        Task { await model.connect(peerKey: peerKey, name: hostName) }
                    }
                }

                if model.isConnecting {
                    ClientWireframe.Page()
                } else if model.isAllowed == false {
                    VStack(spacing: Theme.Space.s) {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: L10n.text("apple.clienthostworkspacesview.0_has_not_let_this_device_in_yet.e161eb1e", "\(hostName)"),
                            message: L10n.text("apple.clienthostworkspacesview.folders_files_terminals_and_the_agents_run.22c37ee2"),
                            actionTitle: model.isRequesting ? L10n.text("apple.clienthostworkspacesview.asking.0b832840") : L10n.text("apple.clienthostworkspacesview.request_access.b06f1662"),
                            actionIcon: .approve,
                            action: {
                                showApproval = true
                                Task { await model.requestAccess(peerKey: peerKey) }
                            },
                            art: .workspaceAccess
                        )
                        if let notice = model.requestNotice {
                            let limited = notice.lowercased().contains("several times")
                                || notice.lowercased().contains("wait an hour")
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: limited ? "hourglass" : "paperplane")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 20)
                                Text(notice)
                                    .font(ClientType.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
                            }
                        }
                        HStack(spacing: Theme.Space.m) {
                            Button(L10n.text("apple.clienthostworkspacesview.how_to_approve.e0fc7247"), .help) { showApproval = true }
                                .font(ClientType.label.weight(.semibold))
                                .tint(Theme.accent)
                            Spacer(minLength: 0)
                            NavigationLink {
                                ClientAddThisDevice(peer: peerKey, hostName: hostName) {
                                    Task { await model.connect(peerKey: peerKey, name: hostName) }
                                }
                            } label: {
                                Label(L10n.text("apple.clienthostworkspacesview.i_have_a_code.b090f9d2"), systemImage: ActionIcon.pair.symbol)
                                    .font(ClientType.label.weight(.semibold))
                            }
                            .tint(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                    }
                    .sheet(isPresented: $showApproval) {
                        ClientAccessApprovalSheet(
                            hostName: hostName,
                            peerKey: peerKey,
                            isHeadless: showsHeadlessInstructions,
                            requestNotice: model.requestNotice,
                            isRequesting: model.isRequesting,
                            onRequestAgain: { Task { await model.requestAccess(peerKey: peerKey) } },
                            onGranted: { Task { await model.connect(peerKey: peerKey, name: hostName) } }
                        )
                    }
                } else if model.folders.isEmpty, model.sessions.isEmpty {
                    if let message = model.errorMessage {
                        let lower = message.lowercased()
                        if lower.contains("no_such_peer") || lower.contains("no direct address")
                            || lower.contains("peer_not_found") || lower.contains("no such peer") {
                            if showsHeadlessInstructions {
                                HeadlessReachRecoveryCard(name: hostName) {
                                    Task { await model.connect(peerKey: peerKey, name: hostName) }
                                }
                            } else {
                                RemoteReachRecoveryCard(name: hostName) {
                                    Task { await model.connect(peerKey: peerKey, name: hostName) }
                                }
                            }
                        } else {
                            ClientErrorCard(message: message) {
                                Task { await model.connect(peerKey: peerKey, name: hostName) }
                            }
                        }
                    } else {
                        VStack(spacing: Theme.Space.s) {
                            ClientEmptyState(
                                kind: .nothingYet,
                                title: L10n.text("common.projects.first_title"),
                                message: L10n.text("apple.clienthostworkspacesview.give_0_a_folder_choose_one_it_already_has.bfd23a13", "\(hostName)"),
                                art: .projects
                            )
                            NavigationLink {
                                ClientFolderPicker(peer: peerKey, hostName: hostName) { _ in
                                    Task { await model.connect(peerKey: peerKey, name: hostName) }
                                }
                            } label: {
                                Label(L10n.text("apple.clienthostworkspacesview.choose_a_folder.5c71b8cd"), systemImage: ActionIcon.reveal.symbol)
                                    .font(ClientType.label)
                            }
                            .tint(Theme.accent)
                            NavigationLink {
                                ClientCloneRepository(peer: peerKey, hostName: hostName) { _ in
                                    Task { await model.connect(peerKey: peerKey, name: hostName) }
                                }
                            } label: {
                                Label(L10n.text("apple.clienthostworkspacesview.clone_a_repository.749e5d4d"), systemImage: ActionIcon.download.symbol)
                                    .font(ClientType.label)
                            }
                            .tint(Theme.accent)
                        }
                    }
                }

                if model.isAllowed == true && !model.isConnecting, layout.allTasksVisible {
                    ClientAllTasksLink(peer: peerKey, hostName: hostName).padding(Theme.Space.m).cardSurface()
                }
                if !model.folders.isEmpty || !model.sessions.isEmpty || !model.recentChats.isEmpty {
                    ForEach(layout.sections) { section in
                        hostWorkSection(section)
                    }
                    if layout.sections.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(L10n.text("apple.clienthostworkspacesview.your_projects_are_clear.c7d87ca8"))
                                .font(ClientType.label.weight(.medium))
                            Text(L10n.text("apple.clienthostworkspacesview.folders_chats_and_sessions_are_switched_of.2cb24a2f"))
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.m)
                        .cardSurface()
                        .padding(.top, Theme.Space.s)
                    }
                    Button(L10n.text("apple.clienthostworkspacesview.customize_projects.00ab91c5"), .layout) { customizing = true }
                        .buttonStyle(.plain)
                        .font(ClientType.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.top, Theme.Space.xs)
                }

                ClientSecurityCard(peerKey: peerKey, peerName: hostName)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(hostName)
        .searchable(text: $search, prompt: L10n.text("apple.clienthostworkspacesview.search_projects.9e079c7d"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("host-\(peerKey)") {
                await model.connect(peerKey: peerKey, name: hostName)
            }
        }
        .task { await model.connect(peerKey: peerKey, name: hostName) }
        .task(id: peerKey) {
            if let headless = try? await Bridge.peerHeadless(peerKey) {
                guard !Task.isCancelled else { return }
                isHeadless = headless
            } else {
                guard !Task.isCancelled else { return }
                isHeadless = isHeadlessPlatform(accountPlatform)
            }
        }
        .fullScreenCover(item: $model.activeTerminal) { session in
            ClientTerminalScreen(
                session: session,
                onClose: { model.activeTerminal = nil }
            )
        }
        .sheet(item: $starting) { section in
            ClientFolderChooserSheet(
                hostName: hostName,
                folders: model.folders,
                title: section == .chat ? L10n.text("apple.clienthostworkspacesview.new_chat_in.510ac43f") : L10n.text("apple.clienthostworkspacesview.new_session_in.30d4568b")
            ) { folder in
                open(folder, section: section)
            }
        }
        .sheet(isPresented: $customizing) {
            ClientWorkspacesEditor(layout: layout)
        }
    }

    @ViewBuilder
    private func hostWorkSection(_ section: WorkspacesSection) -> some View {
        switch section {
        case .folders:
            hostFoldersSection
        case .recentChats:
            ClientRecentChatsSection(
                peer: peerKey,
                hostName: hostName,
                folders: model.folders,
                chats: model.recentChats,
                onNewChat: { starting = .chat }
            )
            .padding(.top, Theme.Space.s)
        case .sessions:
            hostSessionsSection
        }
    }

    @ViewBuilder
    private var hostFoldersSection: some View {
        if !model.folders.isEmpty {
            HStack(alignment: .center) {
                ClientSectionTitle(title: L10n.text("common.projects"), mark: "mark_archive")
                Spacer(minLength: Theme.Space.s)
                NavigationLink {
                    ClientFolderPicker(peer: peerKey, hostName: hostName) { _ in
                        Task { await model.connect(peerKey: peerKey, name: hostName) }
                    }
                } label: {
                    Text(L10n.text("common.add"))
                        .font(ClientType.caption.weight(.semibold))
                }
                .tint(Theme.accent)
                NavigationLink {
                    ClientCloneRepository(peer: peerKey, hostName: hostName) { _ in
                        Task { await model.connect(peerKey: peerKey, name: hostName) }
                    }
                } label: {
                    Text(L10n.text("apple.clienthostworkspacesview.clone.5779f32f"))
                        .font(ClientType.caption.weight(.semibold))
                }
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, Theme.Space.s)
            ClientAdaptiveCards {
                ForEach(ChatStartPage.generalFirst(model.folders).filter {
                    search.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(search)
                        || $0.path.localizedCaseInsensitiveContains(search)
                }) { folder in
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
                    .modifier(ClientProjectRename(peer: peerKey, folder: folder,
                        onChanged: { await model.connect(peerKey: peerKey, name: hostName) }))
                }
            }
        }
    }

    @ViewBuilder
    private var hostSessionsSection: some View {
        if !model.sessions.isEmpty || !model.folders.isEmpty {
            HStack(alignment: .center) {
                ClientSectionTitle(title: L10n.text("apple.clienthostworkspacesview.all_sessions.78648d4d"), mark: "mark_terminal")
                Spacer(minLength: Theme.Space.s)
                if !model.folders.isEmpty {
                    Button(L10n.text("apple.clienthostworkspacesview.new_terminal.fe544556"), .create) { starting = .sessions }
                        .font(ClientType.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, Theme.Space.s)
            ForEach(model.sessions) { session in
                Button {
                    model.open(session, peer: peerKey)
                } label: {
                    ClientSessionRow(session: session, displayName: SidebarTerminalNames.shared.name(peer: peerKey, workspaceID: session.workspaceID, sessionID: session.id))
                }
                .buttonStyle(.plain)
                .modifier(ClientTerminalActions(peer: peerKey, workspaceID: session.workspaceID ?? "",
                    folderName: model.folders.first { ClientRemote.rawWorkspaceID(of: $0) == session.workspaceID || $0.id == session.workspaceID }?.name ?? L10n.text("apple.clienthostworkspacesview.project.98595978"),
                    info: session, onDuplicate: { copied in model.open(copied, peer: peerKey); Task { await model.connect(peerKey: peerKey, name: hostName) } }))
            }
            if model.sessions.isEmpty {
                Text(L10n.text("apple.clienthostworkspacesview.nothing_running_start_one_from_a_folder.f1d69e99"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func open(_ folder: WorkspaceFolder, section: WorkspaceSection) {
        let raw = ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
        navigation.open(folderID: "remote:\(peerKey):\(raw)", section: section)
        navigation.pushFolder(peerKey: peerKey, hostName: hostName, folder: folder, section: section)
    }

}

@Observable
@MainActor
final class ClientHostWorkspacesModel {
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var sessions: [PtySessionInfo] = []
    private(set) var recentChats: [ChatRecentConversation] = []
    private(set) var errorMessage: String?
    private(set) var isConnecting = false
    private(set) var reachedHost: Bool?
    private(set) var isAllowed: Bool?
    private(set) var requestNotice: String?
    private(set) var isRequesting = false
    private var accessWatch: Task<Void, Never>?
    var activeTerminal: ClientTerminalSession?
    private let owner = WorkSessionContext.shared.scope

    private var isCurrent: Bool { owner != nil && owner == WorkSessionContext.shared.scope && !Task.isCancelled }
    private func requireCurrent() throws { if !isCurrent { throw CancellationError() } }

    func connect(peerKey: String, name: String) async {
        guard isCurrent, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        accessWatch?.cancel()
        accessWatch = nil
        errorMessage = nil
        do {
            await ClientDeviceName.publish()
            try requireCurrent()
            let peer = try await Bridge.pair(key: peerKey, label: name, address: "")
            try requireCurrent()
            _ = try await Bridge.setTunnel(true)
            try requireCurrent()
            let allowed = try await Bridge.workspaceAccessAllowed(peer: peer.key)
            try requireCurrent()
            isAllowed = allowed
            reachedHost = true
            guard allowed else {
                folders = []
                sessions = []
                recentChats = []
                if requestNotice == nil {
                    await requestAccess(peerKey: peerKey)
                }
                try requireCurrent()
                watchForAccess(peerKey: peerKey, name: name)
                return
            }
            async let loadedFolders = Bridge.remoteWorkspaces(peer: peer)
            async let loadedSessions = ClientRemote.ptyList(peer: peer.key)
            async let loadedChats = ClientRemote.recentChats(peer: peer.key)
            let freshFolders = try await loadedFolders
            let freshSessions = (try? await loadedSessions) ?? []
            let freshChats = (try? await loadedChats) ?? []
            try requireCurrent()
            folders = freshFolders
            sessions = freshSessions
            recentChats = freshChats
        } catch {
            guard isCurrent else { return }
            errorMessage = error.localizedDescription
            folders = []
            sessions = []
            recentChats = []
            reachedHost = false
            isAllowed = nil
        }
    }

    func requestAccess(peerKey: String) async {
        guard isCurrent, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            let answer = try await Bridge.askWorkspaceAccess(peer: peerKey)
            try requireCurrent()
            if answer.granted == true {
                requestNotice = L10n.text("apple.clienthostworkspacesview.this_device_already_has_access_pull_to_ref.06b896c9")
            } else {
                requestNotice = L10n.text("apple.clienthostworkspacesview.asked_on_that_computer_run_tokenstat_host.40af0490")
            }
        } catch {
            guard isCurrent else { return }
            requestNotice = error.localizedDescription
        }
    }

    private func watchForAccess(peerKey: String, name: String) {
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            for _ in 0..<ClientAccessWatch.attempts {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: ClientAccessWatch.interval)
                guard !Task.isCancelled, let self, self.isCurrent else { return }
                guard let allowed = try? await Bridge.workspaceAccessAllowed(peer: peerKey),
                      allowed
                else { continue }
                guard self.isCurrent else { return }
                self.accessWatch = nil
                await self.connect(peerKey: peerKey, name: name)
                return
            }
        }
    }

    func open(_ info: PtySessionInfo, peer: String) {
        guard isCurrent else { return }
        activeTerminal = ClientTerminalSession(peer: peer, info: info)
    }
}

#endif
