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
    @State private var addAfterChoosingHost = false
    private var draft: ChatStartDraft { navigation.newChatDraft }
    private var host: ClientHost? { workspaces.hosts.first { $0.peerKey == workspaces.connectedKey } }

    var body: some View {
        NavigationStack {
            page
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
                        Button(host.name, systemImage: "desktopcomputer") { Task { await choose(host, thenAdd: addAfterChoosingHost) } }
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

    /// New chat is a first-class action on both layouts: the iPad keeps it at
    /// the top of the sidebar and the phone in the Projects bar, whatever the
    /// account has on it. So it is pressed by people with no computer paired
    /// and by people whose account cannot currently connect, and what it used to open for
    /// both was the whole composer with a Send that could never fire. A
    /// disabled control is not an answer to "why can I not start a chat".
    /// Projects already answers both questions, in these words.
    @ViewBuilder private var page: some View {
        if !remoteAllowed, account.signedIn {
            ZStack {
                ChatStartGlassField.ground.ignoresSafeArea()
                ClientEmptyState(
                    kind: .needsAccount,
                    title: L10n.text("apple.clientnewchatscreen.remote_is_on_patron.d25dea13"),
                    message: L10n.text("apple.clientnewchatscreen.running_a_conversation_on_your_computer_is.ba662608"),
                    actionTitle: L10n.text("common.refresh"), actionIcon: .refresh,
                    action: { Task { await account.load() } }, art: .remoteGate
                ).padding(.horizontal, 24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspaces.hosts.isEmpty, draft.text.isEmpty, draft.attachments.isEmpty {
            reason(kind: .nothingYet, art: .connect,
                   title: L10n.text("apple.clientnewchatscreen.no_machine_yet.3ea83dc9"),
                   message: L10n.text("apple.clientnewchatscreen.a_conversation_runs_an_agent_on_a_computer.3bed8f6c"),
                   actionTitle: L10n.text("apple.clientnewchatscreen.set_up_a_machine.43e10e13"),
                   icon: .connect, request: .machineSetup)
        } else if host == nil, !workspaces.hosts.isEmpty, draft.text.isEmpty, draft.attachments.isEmpty {
            ZStack {
                Theme.background.ignoresSafeArea()
                if workspaces.isConnecting != nil {
                    ProgressView(L10n.text("common.new_chat.connecting"))
                } else if let waitingHost = workspaces.awaitingAccessHost {
                    VStack(spacing: Theme.Space.m) {
                        ClientAwaitingAccessCard(hostName: waitingHost, isHeadless: isHeadlessHost(named: waitingHost))
                        Button(L10n.text("common.new_chat.choose_host"), .connect) {
                            addAfterChoosingHost = false; choosingHost = true
                        }
                    }.padding(.horizontal, 24)
                } else {
                    ClientEmptyState(
                        kind: .nothingYet,
                        title: L10n.text("common.new_chat.choose_host"),
                        message: L10n.text("common.new_chat.connect_host_message"),
                        actionTitle: L10n.text("common.new_chat.choose_host"),
                        actionIcon: .connect,
                        action: { addAfterChoosingHost = false; choosingHost = true }
                    ).padding(.horizontal, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChatStartPage(draft: draft, repositories: workspaces.folders,
                          hostPicker: AnyView(hostPicker), allowsSend: workspaces.isConnecting == nil && host != nil,
                          repositoriesLoading: workspaces.isConnecting != nil,
                          onAdd: addRepository,
                          onSend: { Task { await send() } })
        }
    }

    /// Why there is no composer here, on the same floor the page would have
    /// been drawn on.
    private func reason(kind: ClientEmptyKind, art: EmptyArtKind, title: String, message: String,
                        actionTitle: String, icon: ActionIcon, request: ClientNavigationModel.NewChatRequest) -> some View {
        ZStack {
            ChatStartGlassField.ground.ignoresSafeArea()
            ClientEmptyState(kind: kind, title: title, message: message, actionTitle: actionTitle,
                             actionIcon: icon, action: { leave(for: request) }, art: art)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Setup is a sheet owned by the root. The root starts it once this
    /// screen has gone, rather than presenting it behind the closing page.
    private func leave(for request: ClientNavigationModel.NewChatRequest) {
        navigation.pendingNewChatRequest = request
        navigation.showingNewChat = false
    }

    /// The plan's own answer, with the account's flag ahead of the tier it was
    /// derived from. Twin of the test `ClientWorkspacesView` makes.
    private var remoteAllowed: Bool {
        if let remote = account.account?.canRemote { return remote }
        let tier = account.account?.tier?.lowercased()
        return ["free", "supporter", "patron", "legend"].contains(tier)
    }

    private func isHeadlessHost(named host: String) -> Bool {
        let machine = (account.account?.machines ?? []).first {
            ($0.label?.isEmpty == false ? $0.label : $0.machineID) == host
        }
        return isHeadlessPlatform(machine?.platform) || isHeadlessPlatform(host)
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
        else { addAfterChoosingHost = true; choosingHost = true }
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
        let deadline = ContinuousClock.now.advanced(by: ChatStartPreparation.budget)
        defer { draft.failed(submission, message: nil); draft.finishPresentation(submission) }
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
        // The host conversation exists now. Leave, a failed draft, or a failed
        // fast-mode change has to delete it or the sidebar keeps an empty chat.
        func abandon(_ message: String?) async {
            let preserved = message ?? reader.error
            if submission.owner.scope == WorkSessionContext.shared.scope {
                await reader.remove(created)
            }
            draft.failed(submission, message: preserved)
        }
        guard current(), reader.selected?.id == created.id,
              await reader.installLandingDraft(submission, permits: current) else {
            await abandon(reader.error)
            return
        }
        if submission.agent.fastMode {
            await reader.update(fastMode: true)
            guard current(), reader.selected?.id == created.id, reader.selected?.fastMode == true, reader.error == nil else {
                await abandon(reader.error ?? L10n.text("common.new_chat.setup_changed"))
                return
            }
        }
        guard current(), reader.selected?.id == created.id else {
            await abandon(nil)
            return
        }
        draft.transferred(submission, preparingPresentation: true)
        await ChatStartPreparation.preload(until: deadline) { await reader.sendInitialDraft() }
        guard !Task.isCancelled, navigation.showingNewChat, workspaces.connectedKey == host.peerKey,
              workspaces.folders.contains(where: { $0.id == submission.repositoryID }),
              draft.ownsPresentation(submission, scope: WorkSessionContext.shared.scope,
                                     session: WorkSessionContext.shared.generation) else { return }
        reader.prepareInitialPresentation()
        navigation.showingNewChat = false
        navigation.destination = .workspaces
        let presentation = UUID()
        navigation.pushOwned(ClientOwnedPush(id: presentation, content: AnyView(
            ClientRecentChatView(peer: host.peerKey, workspaceID: raw, folderName: folder.name,
                hostName: host.name, chatID: created.id, retainedSession: session)
                .environment(\.clientChatPresentationID, presentation)
        )), from: nil)
    }
}
#endif
