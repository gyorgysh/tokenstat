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
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var projectTransitions
    @State private var model = ClientHostWorkspacesModel()
    /// Which folder chooser is showing, if any. Chats and sessions live
    /// inside folders, so starting one means picking the folder first.
    @State private var starting: WorkspaceSection?
    @State private var search = ""
    @State private var customizing = false
    @State private var layout = WorkspacesLayout.shared
    /// The approval explainer. Opening it is part of asking: the request fires
    /// and the sheet shows where it went and what answers it.
    @State private var showApproval = false

    /// Whether the host reports no display layer, which changes what "it is
    /// not answering" means and what somebody can do about it. Probed live:
    /// the account record carries no platform, which is only the fallback
    /// when the host cannot answer.
    @State private var isHeadless = false

    private var accountPlatform: String? {
        (account.account?.machines ?? [])
            .first { $0.publicIdentity?.caseInsensitiveCompare(peerKey) == .orderedSame }?
            .platform
    }

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

                // When content is already visible, keep an unobtrusive error
                // above it. With no content, the recovery card below is the
                // whole answer; a banner plus an empty state used to repeat
                // the same failure without clarifying what to do on the Mac.
                if let message = model.errorMessage,
                   !model.folders.isEmpty || !model.sessions.isEmpty {
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
                            // The code path lives beside the request path, not
                            // below two paragraphs: it is the alternative, and
                            // on a server with no SSH it is the only one.
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
                            isHeadless: isHeadless,
                            requestNotice: model.requestNotice,
                            isRequesting: model.isRequesting,
                            onRequestAgain: { Task { await model.requestAccess(peerKey: peerKey) } },
                            onGranted: { Task { await model.connect(peerKey: peerKey, name: hostName) } }
                        )
                    }
                } else if model.folders.isEmpty, model.sessions.isEmpty {
                    if let message = model.errorMessage {
                        // Only the relay's "never registered" failure is a
                        // Remote Reach setup problem. A timeout, refusal, or
                        // LAN drop where Reach is already on needs wake/retry,
                        // not the 2-step setup card.
                        let lower = message.lowercased()
                        if lower.contains("no_such_peer") || lower.contains("no direct address")
                            || lower.contains("peer_not_found") || lower.contains("no such peer") {
                            if isHeadless {
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
                        // Not "no folders". A machine with none is a machine
                        // waiting to be given one, and both ways to do that
                        // are here rather than described.
                        VStack(spacing: Theme.Space.s) {
                            ClientEmptyState(
                                kind: .nothingYet,
                                title: L10n.text("apple.clienthostworkspacesview.nothing_to_work_on_yet.80d6fed9"),
                                message: L10n.text("apple.clienthostworkspacesview.give_0_a_folder_choose_one_it_already_has.bfd23a13", "\(hostName)"),
                                art: .noMachine
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
        .clientSwipeActionsContainer()
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
                isHeadless = headless
            } else {
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
                ForEach(model.folders.filter {
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
                        .clientProjectTransition(id: folder.id, in: projectTransitions, enabled: !reduceMotion)
                    } label: {
                        ClientFolderRow(folder: folder)
                            .clientProjectTransitionSource(id: folder.id, in: projectTransitions)
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

        /// Open a folder's section to start something there. The launch tiles and
    /// the chat composer already live in the folder; this only gets there.
    /// Both roads: `open` for the sidebar layout, the push for the tab
    /// layout, which observes the destination but not the folder.
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
                requestNotice = L10n.text("apple.clienthostworkspacesview.this_device_already_has_access_pull_to_ref.06b896c9")
            } else {
                requestNotice = L10n.text("apple.clienthostworkspacesview.asked_on_that_computer_run_tokenstat_host.40af0490")
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
