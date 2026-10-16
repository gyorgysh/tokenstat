// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientNewChatScreen: View {
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientWorkspacesModel.self) private var workspaces
    @Environment(ClientChatSessions.self) private var sessions
    @Environment(AccountModel.self) private var account
    @State private var addingRepository = false
    @State private var choosingHost = false
    private var draft: ChatStartDraft { navigation.newChatDraft }
    private var host: ClientHost? { workspaces.hosts.first { $0.peerKey == workspaces.connectedKey } }

    var body: some View {
        NavigationStack {
            ChatStartPage(draft: draft, repositories: workspaces.folders,
                          hostPicker: AnyView(hostPicker), allowsSend: workspaces.isConnecting == nil && host != nil,
                          onAdd: addRepository,
                          onSend: { Task { await send() } })
                .navigationTitle(L10n.text("apple.clientchatview.new_chat.db18382a"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("common.close")) { navigation.showingNewChat = false }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let error = workspaces.errorMessage {
                        Text(error).font(Theme.caption).foregroundStyle(Theme.danger).padding()
                    } else if let message = workspaces.infoMessage {
                        Text(message).font(Theme.caption).foregroundStyle(.secondary).padding()
                    }
                }
                .sheet(isPresented: $addingRepository) {
                    if let host {
                        NavigationStack {
                            ClientFolderPicker(peer: host.peerKey, hostName: host.name) { added in
                                addingRepository = false
                                let scope = WorkSessionContext.shared.scope
                                let generation = WorkSessionContext.shared.generation
                                Task {
                                    await workspaces.refresh(account: account.account)
                                    guard scope == WorkSessionContext.shared.scope, generation == WorkSessionContext.shared.generation,
                                          navigation.showingNewChat, workspaces.connectedKey == host.peerKey else { return }
                                    draft.repositoryID = "remote:\(host.peerKey):\(ClientRemote.rawWorkspaceID(of: added) ?? added.id)"
                                }
                            }
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(L10n.text("common.cancel")) { addingRepository = false }
                                }
                            }
                        }
                    }
                }
                .confirmationDialog(L10n.text("common.new_chat.choose_host"), isPresented: $choosingHost, titleVisibility: .visible) {
                    ForEach(workspaces.hosts, id: \.peerKey) { host in
                        Button(host.name, systemImage: "desktopcomputer") { Task { await choose(host, thenAdd: true) } }
                    }
                    Button(L10n.text("common.devices"), systemImage: "desktopcomputer") {
                        navigation.showingNewChat = false
                        navigation.destination = .machines
                    }
                }
        }
        .task {
            draft.activate(scope: WorkSessionContext.shared.scope, session: WorkSessionContext.shared.generation)
            await workspaces.refresh(account: account.account)
            await workspaces.autoConnectLastHost()
        }
        .onChange(of: WorkSessionContext.shared.generation) { _, generation in
            draft.activate(scope: WorkSessionContext.shared.scope, session: generation)
        }
        .onDisappear { draft.retire() }
    }

    private var hostPicker: some View {
        Menu {
            ForEach(workspaces.hosts, id: \.peerKey) { host in
                Button(host.name, systemImage: "desktopcomputer") { Task { await choose(host, thenAdd: false) } }
            }
            Button(L10n.text("common.devices"), systemImage: "desktopcomputer") {
                navigation.showingNewChat = false
                navigation.destination = .machines
            }
        } label: {
            Label(host?.name ?? L10n.text("common.new_chat.choose_host"), systemImage: "desktopcomputer")
                .font(Theme.caption).foregroundStyle(.secondary)
                .frame(minHeight: 32).contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.text("common.new_chat.choose_host"))
    }

    private func addRepository() {
        if host != nil { addingRepository = true }
        else { choosingHost = true }
    }

    private func choose(_ host: ClientHost, thenAdd: Bool) async {
        let scope = WorkSessionContext.shared.scope
        let generation = WorkSessionContext.shared.generation
        draft.repositoryID = nil
        await workspaces.connect(host)
        guard navigation.showingNewChat, scope == WorkSessionContext.shared.scope,
              generation == WorkSessionContext.shared.generation,
              workspaces.connectedKey == host.peerKey else { return }
        if thenAdd { addingRepository = true }
    }

    private func send() async {
        guard workspaces.isConnecting == nil, let host, let submission = draft.begin(available: Set(workspaces.folders.map(\.id))),
              let folder = workspaces.folders.first(where: { $0.id == submission.repositoryID }) else { return }
        defer { draft.failed(submission, message: nil) }
        let raw = ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
        func current() -> Bool {
            !Task.isCancelled && navigation.showingNewChat && workspaces.connectedKey == host.peerKey
                && draft.accepts(submission, scope: WorkSessionContext.shared.scope, session: WorkSessionContext.shared.generation)
                && workspaces.folders.contains(where: { $0.id == submission.repositoryID })
        }
        let session = ClientChatSession()
        let reader = session.model
        reader.newChatChoice = submission.agent
        await session.load(workspaceID: raw, peer: host.peerKey)
        guard current() else { return }
        guard reader.error == nil, reader.isReady(for: raw), let created = await reader.create() else {
            draft.failed(submission, message: reader.error ?? L10n.text("apple.chatview.chat_unavailable.a45aae80"))
            return
        }
        guard current(), reader.selected?.id == created.id,
              await reader.installLandingDraft(submission, permits: current) else {
            draft.failed(submission, message: reader.error)
            return
        }
        if submission.agent.fastMode {
            await reader.update(fastMode: true)
            guard current(), reader.selected?.id == created.id, reader.selected?.fastMode == true, reader.error == nil else {
                draft.failed(submission, message: reader.error ?? L10n.text("common.new_chat.setup_changed"))
                return
            }
        }
        guard current(), reader.selected?.id == created.id else { return }
        draft.transferred(submission)
        navigation.showingNewChat = false
        navigation.destination = .workspaces
        let presentation = UUID()
        navigation.pushOwned(ClientOwnedPush(id: presentation, content: AnyView(
            ClientRecentChatView(peer: host.peerKey, workspaceID: raw, folderName: folder.name,
                hostName: host.name, chatID: created.id, retainedSession: session)
                .environment(\.clientChatPresentationID, presentation)
        )), from: nil)
        await reader.sendInitialDraft()
    }
}
#endif
