// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import SwiftUI
import UIKit

/// Conversations in this folder, on the machine that owns it.
///
/// A list first, the way Notes and Tasks are lists. Tapping one opens the
/// transcript. Setup lives in the conversation until the first turn, then
/// behind Edit setup, because the phone has no inspector column.
struct ClientChatView: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    var hostName: String = ""
    /// The folder, so a turn's changes can be opened for review from the
    /// conversation. Nil leaves Review off.
    var folder: WorkspaceFolder? = nil
    /// Launcher entry: skip the list and land in the conversation worth
    /// returning to, creating the first one when this folder has none.
    var openConversationOnAppear = false
    var retainedSession: ClientChatSession? = nil

    @Environment(ClientChatSessions.self) private var sessions
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.clientChatHandoffID) private var handoffID

    var body: some View {
        ClientChatContent(peer: peer, workspaceID: workspaceID, folderName: folderName,
            hostName: hostName, folder: folder, openConversationOnAppear: openConversationOnAppear,
            session: sessions.session(peer: peer, workspace: workspaceID, retaining: retainedSession),
            publicationIntent: navigation.chatHandoff.intent, handoffID: handoffID,
            publicationLayout: navigation.stackGeneration)
            .id(ClientChatSessions.Key(peer: peer, workspace: workspaceID, conversation: nil))
    }
}

private struct ClientChatContent: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    let hostName: String
    let folder: WorkspaceFolder?
    let openConversationOnAppear: Bool
    let session: ClientChatSession
    @State var publicationIntent: UInt64
    @State var handoffID: UUID?
    @State var publicationLayout: UInt64
    @State private var viewer = UUID()
    @State private var visible = false
    @Environment(\.clientChatPresentationID) private var presentationID
    private var model: ChatModel { session.model }
    private var loaded: Bool {
        get { session.loaded }
        nonmutating set { session.loaded = newValue }
    }
    @State private var search = ""
    @State private var agent = ""
    @State private var runningOnly = false
    @State private var alphabetical = false
    private var retainedThread: ChatConversation? {
        get { session.retainedThread }
        nonmutating set { session.retainedThread = newValue }
    }
    @State private var deleteAll = false
    @State private var deleteAllOwner: WorkReference.Scope?
    @State private var supportsDeleteAll = false

    private var filteredChats: [ChatConversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = model.folderID ?? ""
        return model.chats.filter {
            // Chats opened and never used stay out, apart from the open one.
            !model.isUntouched($0, in: folder)
            && (agent.isEmpty || $0.backend == agent) && (!runningOnly || $0.running)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || (model.backend(for: $0.backend)?.label ?? $0.backend).localizedCaseInsensitiveContains(query)
                    || ($0.model?.localizedCaseInsensitiveContains(query) ?? false))
        }.sorted {
            alphabetical ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : ($0.lastMessageAtMs ?? $0.updatedAtMs) > ($1.lastMessageAtMs ?? $1.updatedAtMs)
        }
    }
    /// The conversation being read, shown in place of the list.
    ///
    /// Not a push, and that is the point. A pushed screen outlives the screen
    /// that pushed it: on the iPad this list lives in a split view's detail
    /// column, and choosing another sidebar row destroys this view while the
    /// stack keeps holding the thread, which then sits on top of the page that
    /// just opened. Nothing outside the stack can pop it, and the stack cannot
    /// be reached: `.id` does not rebuild a split view's detail column and
    /// emptying a bound path does not reach this kind of push. The retained
    /// session keeps this selection while a fold replaces the presentation.
    private var opened: ChatConversation? {
        get { session.opened }
        nonmutating set { session.opened = newValue }
    }
    @State private var pendingDelete: ChatConversation?
    @State private var pendingDeleteOwner: WorkReference.Scope?
    /// A foreground refresh is in flight. Reopening the app onto yesterday's
    /// rows in silence reads as broken sync; the strip says what is happening
    /// until the fresh answer lands.
    @State private var refreshing = false
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(\.scenePhase) private var scenePhase

    private var place: String { folderName.isEmpty ? L10n.text("apple.clientchatview.this_folder.9d6325c8") : folderName }

    var body: some View {
        ZStack {
            if let thread = opened ?? retainedThread {
                ClientChatThread(
                    model: model,
                    session: session,
                    chatID: thread.id,
                    folderName: folderName,
                    hostName: hostName,
                    folder: folder,
                    isActive: opened != nil && ChatViewportAttachment.isCurrentPresentation(visible: visible,
                        layout: publicationLayout, currentLayout: navigation.stackGeneration),
                    onBack: {
                        guard visible, publicationLayout == navigation.stackGeneration else { return }
                        navigation.leaveThread(session: session, presentationID: presentationID)
                        publicationIntent = navigation.chatHandoff.intent
                        publicationLayout = navigation.stackGeneration
                        retainedThread = opened; self.opened = nil
                    },
                    onFork: { copied in
                        guard visible, publicationLayout == navigation.stackGeneration,
                              opened?.id == thread.id else { return }
                        navigation.chooseWithinChat(session: session, presentationID: presentationID)
                        publicationIntent = navigation.chatHandoff.intent
                        publicationLayout = navigation.stackGeneration
                        retainedThread = nil
                        opened = copied
                    },
                    onDelete: didDeleteChat
                )
                .opacity(opened == nil ? 0 : 1)
                .allowsHitTesting(opened != nil)
                .accessibilityHidden(opened == nil)
            }
            if opened == nil {
                list
            }
        }
        // The floating tab bar sits under the composer. SwiftUI's toolbar
        // hide only minimises it on iOS 26. Bound here so Back to the list
        // is an update on the same prober, not a teardown after this view
        // has left the window.
        .clientTabBarHidden(opened != nil)
        .onAppear {
            visible = true
            session.appear(viewer)
            publishChat()
        }
        .onChange(of: opened?.id, initial: true) { previous, id in
            if let id {
                publishChat(id)
            } else {
                if previous != nil, navigation.chatHandoff.reader?.session === session {
                    navigation.leaveThread(session: session, presentationID: presentationID)
                }
                navigation.leaveChat(owner: viewer)
            }
        }
        .onDisappear {
            visible = false
            session.disappear(viewer)
            // Locking the phone must not forget this thread. A tap on its
            // notification would otherwise remount it over itself.
            guard scenePhase == .active else { return }
            navigation.leaveChat(owner: viewer)
        }
        .task {
            await session.load(workspaceID: workspaceID, peer: peer)
            guard !Task.isCancelled, model.error == nil,
                  model.isReady(for: workspaceID), model.peer == peer else { return }
            if await openRequestedChat() { return }
            if openConversationOnAppear { await session.openMostRecent() }
        }
        .onChange(of: navigation.requestedChat) { _, _ in
            Task { await openRequestedChat() }
        }
        .onChange(of: model.selected?.id) { _, _ in publishChat() }
    }

    private func publishChat(_ id: String? = nil) {
        guard visible, let id = id ?? opened?.id else { return }
        navigation.showChat(navigation.reference(peer: peer, workspaceID: workspaceID, chatID: id), owner: viewer,
            sessionKey: .init(peer: peer, workspace: workspaceID, conversation: nil), session: session,
            folderName: folderName, hostName: hostName, presentationID: presentationID,
            intent: publicationIntent, handoffID: handoffID, layout: publicationLayout)
    }

    private var list: some View {
        ClientCardList(
            title: L10n.text("apple.clientchatview.chat.460b3a7d"),
            errorMessage: model.error.map { ClientTunnelCopy.display($0, host: hostName) },
            isLoaded: loaded,
            isEmpty: model.chats.isEmpty,
            emptyText: L10n.text("apple.clientchatview.start_a_chat.d80b1888"),
            emptyArt: .chat(seed: model.defaultFaceSeed),
            emptyMessage: L10n.text("apple.clientchatview.ask_an_agent_to_explore_plan_or_work_in_0.c1ba0fc2", "\(place)"),
            emptyActionTitle: L10n.text("apple.clientchatview.new_chat.db18382a"),
            emptyActionIcon: .create,
            emptyAction: { Task { await create() } },
            refreshKey: "workspace-chat-\(workspaceID)",
            reload: { await reload() }
        ) {
            ClientStatPanels(panels: [
                (L10n.text("apple.clientchatview.conversations.1d432f58"), "\(model.chats.count)", "mark_chat"),
                (L10n.text("common.running"), "\(model.chats.filter(\.running).count)", "mark_running"),
                (L10n.text("apple.clientchatview.agents.279b44d2"), "\(Set(model.chats.map(\.backend)).count)", "mark_agent"),
            ]).clientCardRow()
            // The list gets a name of its own, because the figures above it
            // are about the folder and the rows below are the conversations.
            // Home and Workspaces already label their sections this way.
            ClientSectionTitle(title: L10n.text("apple.clientchatview.conversations.1d432f58"), mark: "mark_chat")
                .clientCardRow()
            HStack {
                Menu {
                    Picker(L10n.text("apple.clientchatview.agent.11b39c93"), selection: $agent) {
                        Text(L10n.text("apple.clientchatview.all_agents.54c32d3e")).tag("")
                        ForEach(Set(model.chats.map(\.backend)).sorted(), id: \.self) { id in
                            Text(model.backend(for: id)?.label ?? id).tag(id)
                        }
                    }
                    Toggle(L10n.text("apple.clientchatview.running_only.48bbf789"), isOn: $runningOnly)
                    Picker(L10n.text("apple.clientchatview.sort.bec69036"), selection: $alphabetical) {
                        Text(L10n.text("apple.clientchatview.recent_first.e23e162b")).tag(false)
                        Text(L10n.text("apple.clientchatview.title_a_z.ab217de6")).tag(true)
                    }
                } label: { Label(L10n.text("apple.clientchatview.filter_sort.f6606a98"), systemImage: ActionIcon.filter.symbol) }
                .frame(minHeight: 44)
                Spacer()
                Text(L10n.text("apple.clientchatview.0_shown.c67ec9a7", "\(filteredChats.count)")).font(ClientType.caption).foregroundStyle(.secondary)
            }.clientCardRow()
            if filteredChats.isEmpty {
                Text(L10n.text("apple.clientchatview.no_matching_conversations_adjust_your_sear.37233882")).font(ClientType.label).foregroundStyle(.secondary).clientCardRow()
            }
            ForEach(filteredChats) { chat in
                HStack {
                    Button {
                        guard visible, publicationLayout == navigation.stackGeneration else { return }
                        navigation.chooseWithinChat(session: session, presentationID: presentationID)
                        publicationIntent = navigation.chatHandoff.intent
                        publicationLayout = navigation.stackGeneration
                        opened = chat
                    } label: {
                        row(chat, draft: model.draftReference(for: chat.id, in: workspaceID))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    ClientChatMenu(model: model, conversation: chat, peer: peer, workspaceID: workspaceID,
                                   hostName: hostName,
                                   onFork: { copied in
                                       guard visible, publicationLayout == navigation.stackGeneration,
                                             opened == nil else { return }
                                       navigation.chooseWithinChat(session: session, presentationID: presentationID)
                                       publicationIntent = navigation.chatHandoff.intent
                                       publicationLayout = navigation.stackGeneration
                                       opened = copied
                                   }, onDelete: didDeleteChat)
                }
                .clientCardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(L10n.text("common.delete"), role: .destructive) {
                        pendingDeleteOwner = WorkSessionContext.shared.scope
                        pendingDelete = chat
                    }
                }
            }
        }
        .searchable(text: $search, prompt: L10n.text("apple.clientchatview.titles_agents_or_models.b7ffdc79"))
        .safeAreaInset(edge: .top, spacing: 0) {
            if showReconnect {
                ClientReconnectBanner(offline: !refreshing && connectivity.status == .offline)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Unsent words are written a third of a second after the last
            // keystroke. Leaving the app can arrive sooner than that.
            guard phase == .active else {
                model.saveDraftNow()
                return
            }
            Task { await foregroundRefresh() }
        }
        .onDisappear { model.saveDraftNow() }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await foregroundRefresh() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("apple.clientchatview.new_chat.db18382a"), .create) { Task { await create() } }
                    .disabled(model.isCreating)
            }
            if supportsDeleteAll && !model.chats.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(L10n.text("apple.clientchatview.delete_all_chats.9753e785"), role: .destructive) {
                            deleteAllOwner = WorkSessionContext.shared.scope
                            deleteAll = true
                        }
                    }
                    label: {
                        Label(L10n.text("apple.clientchatview.chat_list_actions.43ea56ad"), systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .menuIndicator(.hidden)
                }
            }
        }
        .task(id: peer) { supportsDeleteAll = await RemoteHostFeature.chatRemoveAll.isSupported(peer: peer) }
        .confirmationDialog(L10n.text("apple.clientchatview.delete_all_chats.7d0b4340"), isPresented: $deleteAll, titleVisibility: .visible) {
            Button(L10n.text("apple.clientchatview.delete_all_chats.3fbb0f9c"), role: .destructive) {
                let owner = deleteAllOwner
                Task {
                    guard owner != nil, owner == WorkSessionContext.shared.scope,
                          model.peer == peer, model.workspaceID == workspaceID else { return }
                    await model.removeAll(in: workspaceID, peer: peer)
                    guard owner == WorkSessionContext.shared.scope,
                          model.peer == peer, model.workspaceID == workspaceID else { return }
                    if model.error == nil { retainedThread = nil; opened = nil }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.clientchatview.every_chat_in_this_project_on_0_will_be_de.8c6b8cf6", "\(hostName.isEmpty ? L10n.text("apple.clientchatview.the_computer.da52d93a") : hostName)"))
        }
        .confirmationDialog(
            L10n.text("apple.clientchatview.delete_this_chat.848dad9b"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.clientchatview.delete_chat.93291d9c"), role: .destructive) {
                if let chat = pendingDelete {
                    let owner = pendingDeleteOwner
                    Task {
                        guard owner != nil, owner == WorkSessionContext.shared.scope,
                              model.peer == peer, model.workspaceID == workspaceID else { return }
                        let removed = await model.remove(chat, in: workspaceID)
                        guard removed, owner == WorkSessionContext.shared.scope,
                              model.peer == peer, model.workspaceID == workspaceID else { return }
                        didDeleteChat(chat)
                    }
                }
                pendingDelete = nil
            }
            Button(L10n.text("apple.clientchatview.keep_it.fdce5da2"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.text("apple.clientchatview.the_transcript_stays_on_0_until_you_delete.2ccfbdf7", "\(hostName.isEmpty ? L10n.text("apple.clientchatview.the_computer.da52d93a") : hostName)"))
        }
    }

    private func didDeleteChat(_ deleted: ChatConversation) {
        if opened?.id == deleted.id { opened = nil }
        if retainedThread?.id == deleted.id { retainedThread = nil }
    }

    private func row(_ chat: ChatConversation, draft: WorkReference?) -> some View {
        HStack(spacing: Theme.Space.s) {
            HarnessMark(id: chat.backend, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if chat.running {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 7, height: 7)
                    }
                    Text(chat.title)
                        .font(ClientType.label.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let pull = chat.pull {
                        Image(systemName: pull.symbol)
                            .font(ClientType.caption.weight(.medium))
                            .foregroundStyle(pull.tint)
                            .accessibilityLabel(L10n.text("apple.branchpull.chip", "\(pull.number)", pull.stateLabel))
                    }
                    // Words waiting in this thread. The mark reads the draft
                    // store itself, so this list is not rebuilt every time
                    // somebody pauses typing in one of them.
                    ChatDraftMark(reference: draft, size: 10, scalesWithText: true)
                }
                Text(rowDetail(chat))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                RelativeTimeText(date: Date(timeIntervalSince1970: Double(chat.lastMessageAtMs ?? chat.updatedAtMs) / 1000), unitsStyle: .abbreviated)
                    .font(ClientType.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: ActionIcon.next.symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func rowDetail(_ chat: ChatConversation) -> String {
        let agent = model.backend(for: chat.backend)?.label ?? chat.backend
        let mode = chat.mode == "plan" ? L10n.text("apple.clientchatview.plan.fa8ed0bd") : L10n.text("apple.clientchatview.execute.e3a67d95")
        return "\(agent) · \(mode)"
    }

    private func reload() async {
        await session.load(workspaceID: workspaceID, peer: peer, refresh: true)
        // A tap that arrived mid-reload found an empty list and returned
        // without consuming. Retry now that the folder has answered.
        await openRequestedChat()
    }

    private var showReconnect: Bool {
        refreshing || connectivity.status == .offline
    }

    /// Fresh on return, with the strip up while it happens. The list's own
    /// `.task` runs once on appear; minimizing and reopening never
    /// re-appears, so without this the rows sit stale in silence. Stale
    /// complaints die with the attempt: a failure now raises its own error,
    /// so yesterday's modal can never pop for today's retry.
    private func foregroundRefresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        model.error = nil
        await reload()
    }

    private func create() async {
        guard visible, !Task.isCancelled, publicationLayout == navigation.stackGeneration else { return }
        navigation.chooseWithinChat(session: session, presentationID: presentationID)
        publicationIntent = navigation.chatHandoff.intent
        let intent = publicationIntent
        let reader = model
        guard let created = await reader.create(), !Task.isCancelled, visible,
              publicationLayout == navigation.stackGeneration, intent == navigation.chatHandoff.intent,
              session.model === reader, reader.selected?.id == created.id,
              reader.folderID == workspaceID else { return }
        opened = created
    }

    /// A notification named this conversation. Only consume it if it is in
    /// this folder, so a list that is still on screen for another workspace
    /// cannot steal the tap. Already open is a no-op: re-selecting blanks
    /// the transcript.
    @discardableResult
    private func openRequestedChat() async -> Bool {
        guard visible, publicationLayout == navigation.stackGeneration,
              !Task.isCancelled, let requested = navigation.requestedChat,
              let id = WorkDestinationResolver.requestedConversation(requested,
                  scope: WorkSessionContext.shared.scope, peer: peer, workspaceID: workspaceID)
        else { return false }
        let request = navigation.requestedChatGeneration
        let intent = navigation.chatHandoff.intent
        let reader = session.model
        let layout = publicationLayout
        func stillCurrent() -> Bool {
            visible && !Task.isCancelled && session.model === reader
                && layout == navigation.stackGeneration
                && request == navigation.requestedChatGeneration
                && intent == navigation.chatHandoff.intent
                && WorkDestinationResolver.sameConversation(navigation.requestedChat, requested)
                && requested.scope == WorkSessionContext.shared.scope
        }
        // An explicit destination suppresses the launcher's most-recent/new
        // fallback, including when that conversation has been deleted.
        if opened?.id == id, reader.selected?.id == id {
            publicationIntent = intent
            publishChat(id)
            navigation.requestedChat = nil
            return true
        }
        guard let chat = model.chats.first(where: { $0.id == id }) else {
            if loaded, model.error == nil {
                model.error = L10n.text("apple.clientchatview.this_conversation_is_no_longer_available_i.3867a302")
            }
            return true
        }
        await session.select(chat)
        guard stillCurrent(), reader.selected?.id == id else { return false }
        publicationIntent = intent
        opened = chat
        publishChat(id)
        navigation.requestedChat = nil
        return true
    }
}

/// The slim strip both chat screens show while a foreground refresh is in
/// flight, or while the connection is down. A spinner while working, plain
/// words while waiting: the two states ask for different patience.
private struct ClientReconnectBanner: View {
    var offline: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if !offline {
                ProgressView()
                    .tint(Theme.accent)
                    .accessibilityHidden(true)
            }
            Text(offline ? L10n.text("apple.clientchatview.waiting_for_connection.28ee7605") : L10n.text("apple.clientchatview.reconnecting.27b80374"))
                .font(ClientType.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(offline ? L10n.text("apple.clientchatview.waiting_for_connection.f12044f6") : L10n.text("apple.clientchatview.reconnecting.afb118fc"))
    }
}

/// One conversation: setup, transcript, glass composer.
struct ClientChatThread: View {
    @Bindable var model: ChatModel
    var session: ClientChatSession? = nil
    @State private var detail = ChatDetailPreference.shared
    let chatID: String
    let folderName: String
    let hostName: String
    var folder: WorkspaceFolder? = nil
    /// How to leave, when this is shown in place of the chat list rather than
    /// pushed on top of it. `PullDetailView` takes the same closure for the
    /// same reason.
    var isActive = true
    var onBack: (() -> Void)?
    var onFork: ((ChatConversation) -> Void)?
    var onDelete: ((ChatConversation) -> Void)?
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    /// A row the transcript should jump to, set by the pending-approval bar.
    @State private var scrollTarget: String?
    @State private var follow = TranscriptFollowState()
    @State private var window = TranscriptWindow()
    @State private var scrollAccess = ClientTranscriptScrollAccess()
    @State private var readingFrames = ClientTranscriptReadingFrames()
    @State private var readingHold = ChatReadingHold()
    @State private var readingDelivery = TranscriptScrollDelivery()
    @State private var readerMoved = false
    @State private var settleMood: PersonaMood?
    @State private var settleTaskID = UUID()
    /// Bumped on send so the transcript scrolls to the end synchronously,
    /// instead of waiting for the first streamed token to trigger a pin.
    @State private var followPulse = 0
    @State private var presenceOwner = UUID()
    @State private var viewportPlaced = false
    /// Last instant (non-animated) pin. A scrollTo on a lazy stack walks
    /// every row in between, so silent pins share one ~150ms gate, same as
    /// the growth repins. Animated pins always go through.
    @State private var lastSilentPinAt = Date.distantPast
    /// How many newest rows sit below the built slice. Same rule as the Mac:
    /// the slice stays a fixed width, older built rows arrive by sliding it.
    /// Reset on every open.
    @State private var olderOffset = 0
    /// First row of the built slice, when it is not glued to the end. Same
    /// lock as the Mac: the offset is from the newest row, so a turn or a
    /// page would otherwise replace what is on screen.
    @State private var sliceAnchor: String?
    /// Whether rows are reporting where they are. Set from the scroll
    /// callback as the top of the loaded conversation comes near, so the
    /// geometry readers exist for the stretch that can need an anchor and
    /// nowhere else.
    @State private var measuringRows = false
    @State private var showingHandoff = false
    @State private var showingSetup = false
    @State private var showingPersonas = false
    @State private var showingToolsPane = false
    @State private var pushingTools = false
    @State private var urlDropTargeted = false
    @State private var textDropTargeted = false
    @State private var dataDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @State private var previewFile: ChatPreviewedFile?
    /// The folder's changes, opened from a turn's card or the changes pill.
    @State private var reviewingChanges = false
    /// The folder's live git state, for the changes pill and the chip.
    @State private var folderGit: GitStatus?
    @State private var branchPull: BranchPull?
    /// Same strip as the list: reopening onto a stale transcript says what
    /// is happening until the explicit poll below answers.
    @State private var refreshing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The folder's uncommitted work and the branch's pull request, above
    /// the composer, as on the Mac.
    @ViewBuilder
    private var changesRow: some View {
        ChatGitStatusStrip(git: folderGit, pull: branchPull, review: { reviewingChanges = true })
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
    }

    private func loadFolderState() async {
        folderGit = nil
        branchPull = nil
        guard let folder, let peer = model.peer, model.savedCopy == nil else { return }
        let workspace = model.folderID ?? folder.id
        let owner = model.currentReference
        let status = try? await GitCommitTarget(peer: peer, workspaceID: workspace).status()
        guard !Task.isCancelled, owner == model.currentReference, model.peer == peer,
              model.savedCopy == nil else { return }
        folderGit = status?.git
        guard folderGit?.isRepo == true else {
            branchPull = nil
            return
        }
        let answer = try? await Bridge.branchPull(workspaceID: workspace, peer: peer, branch: folderGit?.branch, refresh: true)
        guard !Task.isCancelled, owner == model.currentReference, model.peer == peer,
              model.savedCopy == nil else { return }
        branchPull = answer?.pull
    }

    private var chat: ChatConversation? {
        model.chats.first { $0.id == chatID } ?? model.selected.flatMap { $0.id == chatID ? $0 : nil }
    }

    /// Files, Changes and History for this folder, beside the transcript.
    /// Regular both ways only (iPad, an open iPhone Duo): compact layouts push
    /// the same surface instead, and a large iPhone in landscape is compact
    /// down, so it stays the phone layout.
    private var showsToolsPane: Bool {
        showingToolsPane
            && ClientLayout.hasRoom(horizontal: sizeClass, vertical: verticalSizeClass)
            && model.peer != nil
            && model.workspaceID != nil
    }

    private var toolsIdentity: (peer: String, workspaceID: String)? {
        guard let peer = model.peer, !peer.isEmpty,
              let workspaceID = model.workspaceID, !workspaceID.isEmpty else { return nil }
        return (peer, workspaceID)
    }

    @ViewBuilder
    private func toolsPane(peer: String, workspaceID: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("apple.clientchatview.project.98595978"))
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(Theme.controlGlyph)
                Spacer(minLength: 0)
                Button(action: {
                    showingToolsPane = false
                }) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityLabel(L10n.text("apple.clientchatview.hide_workspace_tools.d56bc00c"))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            ClientWorkspaceToolsView(
                peer: peer,
                workspaceID: workspaceID,
                folderName: folderName,
                hostName: hostName
            )
        }
        .background(Theme.background)
    }

    /// What a pin files this conversation under. Nothing without an account
    /// scope, a verified peer and the folder it belongs to.
    private var pinReference: WorkReference? {
        guard let scope = account.account?.pinnedWorkScope,
              let peer = model.peer, !peer.isEmpty,
              let workspace = model.workspaceID, !workspace.isEmpty
        else { return nil }
        return WorkReference(
            scope: scope, hostIdentity: peer, workspaceID: workspace,
            kind: .conversation, itemID: chatID
        )
    }

    private func checkSavedCopyUpdates() async {
        guard let reference = model.currentReference else { return }
        await model.checkSavedCopyForUpdates {
            guard let peer = model.peer else { return }
            @MainActor func requireCurrent() throws {
                guard !Task.isCancelled, reference.scope == WorkSessionContext.shared.scope,
                      model.currentReference == reference else { throw CancellationError() }
            }
            await ClientDeviceName.publish()
            try requireCurrent()
            _ = try await Bridge.pair(key: peer, label: hostName, address: "")
            try requireCurrent()
            _ = try await Bridge.setTunnel(true)
            try requireCurrent()
            // Access and protocol checks are shared with desktop in ChatModel.
        }
    }

    /// One explicit round trip on return. The poll loop restarts on its own
    /// but sleeps first, so without this the transcript sits a full interval
    /// stale with no strip to say so. Never a re-select: that empties the
    /// transcript and reads it back, which is the screen blanking. Stale
    /// complaints die with the attempt, like the list.
    private func foregroundRefresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        model.error = nil
        if let selected = model.selected, model.events.isEmpty {
            // An older host could return an empty page at the archive's end.
            // A tail poll at that cursor cannot recover the missing history.
            await model.select(selected)
        } else {
            await model.poll()
        }
    }

    private var chatPresentation: some View {
        VStack(spacing: 0) {
            if let chat {
                if model.savedCopy == nil {
                    WorkHandoffOffer(chat: model) { showingHandoff = true }
                }
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // The bar is pinned, not the next row of a stack. Stacked,
                transcript(chat)
                    .overlay {
                        if dropExperienceVisible {
                            ChatDropExperience()
                        }
                    }
                    .clientBottomBar {
                        bar(chat)
                            .padding(.top, Theme.Space.s)
                    }
                    }
                    if showsToolsPane, let peer = model.peer, let workspace = model.workspaceID {
                        ThemeRule.vertical
                        toolsPane(peer: peer, workspaceID: workspace)
                            .frame(width: 320)
                    }
                }
            } else {
                ClientEmptyState(
                    kind: .nothingYet,
                    title: L10n.text("apple.clientchatview.this_chat_is_gone.8a6de141"),
                    message: L10n.text("apple.clientchatview.it_was_deleted_on_0.80f0ae0a", "\(hostName.isEmpty ? L10n.text("apple.clientchatview.the_computer.da52d93a") : hostName)"),
                    art: .chat(seed: model.defaultFaceSeed)
                )
                .padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
        // Do not fight the system's Liquid Glass. On iOS 26 the bar is glass
        // already and any background of ours replaces it with a flat blur, so
        // that system gets nothing from us. Below 26 there is no bar to fight.
        .clientNavigationBarBackground()
        .dropDestination(for: String.self) { items, _ in
            receive(items.map(ChatInboxDrop.text))
            return !items.isEmpty
        } isTargeted: { textDropTargeted = $0 }
        .dropDestination(for: Data.self) { items, _ in
            let drops = items.compactMap(ChatInbox.imageDrop(from:))
            receive(drops)
            return !drops.isEmpty
        } isTargeted: { dataDropTargeted = $0 }
        .dropDestination(for: URL.self) { items, _ in
            let drops = ChatInbox.drops(from: items)
            receive(drops)
            return !drops.isEmpty
        } isTargeted: { urlDropTargeted = $0 }
        .overlay(alignment: .topTrailing) {
            TransientToast(message: $dropNotice, severity: .warning)
                .padding(Theme.Space.m)
        }
        .overlay(alignment: .top) {
            if refreshing || connectivity.status == .offline {
                ClientReconnectBanner(offline: !refreshing && connectivity.status == .offline)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveDraftNow() }
            else if isActive { Task { await model.resumeWaitingConnection() } }
            guard phase == .active, isActive else { return }
            Task { await foregroundRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await foregroundRefresh() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropExperienceVisible)
        .navigationTitle(isActive ? (chat?.title ?? L10n.text("apple.clientchatview.chat.460b3a7d")) : L10n.text("apple.clientchatview.chat.460b3a7d"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive, let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { ActionIcon.back.label(L10n.text("common.chats")) }
                }
            }
            if isActive, let chat, pinReference != nil || model.savedCopy == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    PinToggleButton(reference: pinReference, label: chat.title, folderName: folderName)
                }
                if toolsIdentity != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("apple.clientchatview.project_tools.c50826a7"), .source) {
                            if ClientLayout.hasRoom(horizontal: sizeClass, vertical: verticalSizeClass) {
                                showingToolsPane.toggle()
                            } else {
                                pushingTools = true
                            }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(L10n.text("apple.clientchatview.project_files_changes_and_history.4da56c40"))
                        // The inspector chord stays on the real control.
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
                if model.savedCopy == nil, let tools = toolsIdentity {
                    ToolbarItem(placement: .topBarTrailing) {
                        ClientChatMenu(model: model, conversation: chat, peer: tools.peer,
                            workspaceID: tools.workspaceID, hostName: hostName, onFork: onFork,
                            onSetup: { showingSetup = true }, onHandoff: { showingHandoff = true },
                            onDelete: onDelete, onViewportChoice: beginViewportChoice)
                            .id(chat.id)
                    }
                }
            }
        }
        .navigationDestination(isPresented: $pushingTools) {
            if let tools = toolsIdentity {
                ClientWorkspaceToolsView(
                    peer: tools.peer,
                    workspaceID: tools.workspaceID,
                    folderName: folderName,
                    hostName: hostName
                )
            }
        }
        .sheet(isPresented: $showingHandoff) { WorkHandoffSheet(chat: model) }
        .sheet(isPresented: $reviewingChanges, onDismiss: { Task { await loadFolderState() } }) {
            if let folder, let peer = model.peer {
                NavigationStack {
                    ClientWorkspaceChangesView(peer: peer, workspaceID: model.folderID ?? folder.id,
                                               folder: folder, hostName: hostName)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.text("common.done")) { reviewingChanges = false }
                            }
                        }
                }
            }
        }
        // Asked again when a turn ends, since the agent may have changed
        // files or opened the pull request.
        .task(id: "\(model.busy)|\(isActive)|\(model.folderID ?? "")") {
            guard isActive, !model.busy else { return }
            await loadFolderState()
        }
        .sheet(isPresented: $showingSetup) {
            setupSheet
        }
    }

    var body: some View {
        chatPresentation
        .task(id: chatID) { await loadChat() }
        .task(id: "live-\(chatID)-\(scenePhase == .active)-\(isActive)") {
            guard scenePhase == .active, isActive else { return }
            // Transcript events must not cancel an in-flight capability probe.
            // Retry after offline launch or account verification and heartbeat
            // quiet runs even when no new transcript event is produced.
            while !Task.isCancelled {
                await updateLiveActivity()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task(id: ChatPollWatchIdentity(owner: model.pollingIdentity,
                                       active: scenePhase == .active && isActive)) {
            guard scenePhase == .active, isActive else { return }
            await model.watchPolls()
        }
        // What is on screen, for the local notifier. Without this,
        // `isWatching()` is always false on iOS and on-device banners are
        // never suppressed (host push suppression still works via heartbeat).
        .onChange(of: chatID, initial: true) { _, id in
            if let peer = model.peer, let workspace = model.workspaceID {
                ClientRecentPlaces.shared.record(
                    in: account.account?.recentPlacesScope, peer: peer,
                    workspaceID: workspace, workspaceName: folderName, kind: .chat, itemID: id
                )
            }
            updatePresence()
        }
        .onAppear { updatePresence() }
        .onChange(of: scenePhase) { _, _ in
            updatePresence()
            scrollAccess.refreshAttachment(retryVisibility: true)
        }
        .onChange(of: isActive) { _, active in
            updatePresence()
            if !active { model.saveDraftNow() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await model.resumeWaitingConnection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatAttachmentCachePurged)) { _ in
            model.clearCachedAttachmentMemory()
        }
        // Presented here rather than on the row. A row lives in a lazy stack
        // that is free to tear it down while it is being tapped, and a
        // presentation that goes with it is a tap that does nothing.
        .fullScreenCover(item: $previewFile) { file in
            ClientFilePreview(file: file) { previewFile = nil }
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .onDisappear {
            model.saveDraftNow()
            traceViewport("disappear")
            retireViewport()
            follow.freeze()
            UserPresence.shared.leaveChatSurface(owner: presenceOwner)
        }
        // The host is on the other computer and cannot see this screen. Until
        // it is told, a turn finishing here pushed to this very phone.
        .watching(conversationID: chatID, peer: model.peer, isActive: isActive && model.savedCopy == nil)
        // Optimistic while offline. A modal for a failure the recovery pass
        // is about to erase is a popup, not information: the strip says
        // reconnecting, the foreground refresh retries, and anything still
        // broken once back online raises its own error then.
        .alert(L10n.text("apple.clientchatview.chat_unavailable.a45aae80"), isPresented: Binding(
            get: { isActive && model.error != nil && connectivity.status != .offline },
            set: { if !$0 { model.error = nil } }
        )) {
            Button(L10n.text("apple.clientchatview.ok.565339bc"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error.map { ClientTunnelCopy.display($0, host: hostName) } ?? "")
        }
    }

    private func updatePresence() {
        UserPresence.shared.chatSurface(showing: isActive ? chatID : nil,
            owner: presenceOwner, sceneActive: scenePhase == .active)
    }

    private func loadChat() async {
        guard !Task.isCancelled, isActive else { return }
        // A first task offered by setup, put in the composer rather than
        // sent. Only into an empty one, only once, and only for the folder
        // setup opened: any other thread mounting first must not consume it.
        if model.draft.isEmpty, let scope = navigation.folderID,
           let offered = navigation.takeSuggestedPrompt(for: scope) {
            model.draft = offered
        }
        guard let chat = model.chats.first(where: { $0.id == chatID }) else { return }
        // Already open, with rows on screen. Re-selecting would empty the
        // transcript and read it back, which is this screen blanking and
        // re-scrolling every time it is pushed, including straight after
        // the launcher picked the conversation for you.
        if model.savedCopy == nil && (model.selected?.id != chat.id || model.transcriptItems.isEmpty) {
            guard !Task.isCancelled, isActive else { return }
            if let session { await session.select(chat) }
            else { await model.select(chat) }
        }
        guard !Task.isCancelled, isActive else { return }
        if let current = model.chats.first(where: { $0.id == chatID }) {
            ClientChatReadState.shared.markRead(peer: model.peer, chat: current)
        }
    }

    private func updateLiveActivity() async {
        guard let chat = model.selected, chat.id == chatID, let peer = model.peer,
              let workspaceID = model.workspaceID else { return }
        let done = model.events.reversed().first {
            $0.kind == "agent" && $0.event?.kind == "done" && ($0.atMs ?? .min) >= (chat.runStartedAtMs ?? .max)
        }?.event?.status
        guard chat.running || done != nil else { return }
        let phase: LiveWorkPhase = chat.running ? (model.approvals.isEmpty ? .working : .waiting)
            : (done == "error" ? .failed : done == "stopped" ? .stopped : .done)
        await LiveWorkController.shared.track(chat: chat, peer: peer, projectID: workspaceID, projectName: folderName,
            startedAt: chat.runStartedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                ?? model.turnStartedAt(for: chat.id) ?? Date(), phase: phase, mayStart: {
                    guard let current = model.selected else { return false }
                    return current.id == chat.id && current.running && model.peer == peer && model.workspaceID == workspaceID
                        && (current.runRevision ?? current.sendRevision) == (chat.runRevision ?? chat.sendRevision)
                })
    }

    private var pollingIdentity: String {
        "\(chatID)-\(scenePhase == .active)-\(isActive)"
    }

    /// Same rule as the Mac: a blocked turn takes the composer's place. On a
    /// phone this matters more, not less, because the card scrolls out of a
    /// short viewport in one streamed paragraph.
    @ViewBuilder
    private func bar(_ chat: ChatConversation) -> some View {
        if model.approvals.isEmpty {
            VStack(spacing: Theme.Space.s) {
                // A saved copy explains itself above the composer: what the
                // rows are, when they were kept, and the way back to live.
                if let copy = model.savedCopy {
                    ChatSavedCopyBanner(info: copy, checking: model.checkingSavedCopy,
                        canCheck: model.currentReference?.scope == WorkSessionContext.shared.scope) {
                        Task { await checkSavedCopyUpdates() }
                    }
                    .padding(.horizontal, Theme.Space.s)
                }
                // Pending writing stays available offline for copying or cancellation.
                // Sending and receipt checks require a live, verified owner.
                if let note = chat.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    ChatSteerNoteBanner(note: note) { model.clearSteer() }
                        .padding(.horizontal, Theme.Space.s)
                }
                if !model.pendingQueue.isEmpty {
                        let queueOwner = model.currentReference
                    ChatQueueStrip(
                        items: model.pendingQueue,
                        owner: queueOwner,
                            paused: model.queuePaused,
                            offline: model.savedCopy != nil,
                        onChange: { item, text in model.updateQueued(item, text: text, owner: queueOwner) },
                        onRemove: { model.removeQueued($0, owner: queueOwner) },
                        onSendNow: { item in
                            showNewest()
                            resumeLatest()
                            followPulse += 1
                            Task { await model.sendNow(item, owner: queueOwner) }
                        },
                        onMove: { model.moveQueued(from: $0, to: $1, owner: queueOwner) }
                    )
                    .padding(.horizontal, Theme.Space.s)
                }
                if let backend = model.backend(for: chat.backend), model.savedCopy == nil, model.signInGateRowID == nil {
                    ChatAgentSetupCard(model: model, backend: backend, running: model.busy,
                                       recoveryFailureID: model.signInFailureID)
                        .padding(.horizontal, Theme.Space.s)
                }
                if model.savedCopy == nil, folder != nil {
                    changesRow
                }
                ClientChatComposer(
                    model: model,
                    chat: chat,
                    draft: $model.draft,
                    attachments: model.attachments,
                    previews: model.attachmentPreviews,
                    running: model.busy,
                    sendsAsNote: model.sendsAsNote,
                    placeholder: model.sendsAsNote
                        ? L10n.text("apple.clientchatview.add_a_note_for_the_next_step.4778177a")
                        : (model.busy
                            ? L10n.text("apple.clientchatview.send_after_this_turn.012fc8c3")
                            : L10n.text("apple.clientchatview.ask_about_0.35c322e7", "\(folderName.isEmpty ? L10n.text("apple.clientchatview.this_folder.9d6325c8") : folderName)")),
                    onSend: { submit(from: chat) },
                    onSendNow: { submit(from: chat, sendNow: true) },
                    onStop: { Task { await model.stop() } },
                    onKeyboardDidHide: {
                        guard follow.pinned else { return }
                        followPulse += 1
                    },
                    onAttach: { item, owner in await model.attach(item, to: owner) },
                    onRemove: { model.removeAttachment($0) },
                    onOpenSetup: { if model.savedCopy == nil { showingSetup = true } },
                    onImportURLs: { urls, owner in
                        let drops = ChatInbox.drops(from: urls)
                        Task { await receive(drops, owner: owner) }
                    },
                    onDropURLs: { urls in
                        receive(ChatInbox.drops(from: urls))
                    },
                    onDropText: { items in
                        receive(items.map(ChatInboxDrop.text))
                    },
                    onDropData: { items in
                        receive(items.compactMap(ChatInbox.imageDrop(from:)))
                    },
                    onDropTargeted: { composerDropTargeted = $0 }
                )
            }
        } else {
            ChatApprovalBar(
                approvals: model.approvals,
                resolve: { approval, choice in
                    let owner = model.currentReference
                    Task { await model.resolve(approval, choice: choice, owner: owner) }
                },
                showInTranscript: { approval in
                    scrollTarget = "approval-\(approval.id)"
                }
            )
        }
    }

    private func transcript(_ chat: ChatConversation) -> some View {
        // Once per pass, not once per reader of it. `visibleItems` copies the
        // window out of the conversation every time it is asked, and the
        // `ForEach` and the spinner both ask.
        let rows = visibleItems
        let spinning = TranscriptFollow.spinningRow(rows)
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy on purpose. A long conversation is hundreds of rows of
                // markdown, and a plain stack lays out and re-measures every
                // one of them on every update, whether or not it is anywhere
                // near the screen.
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    TranscriptEarlierHeader(model: model) {
                        window.ask(force: true)
                    }
                    if hiddenAboveCount > 0 {
                        Button(L10n.text("apple.clientchatview.show_0_earlier_messages.2e5e4ab9", "\(hiddenAboveCount)"), .history) {
                            revealEarlier()
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel(L10n.text("apple.clientchatview.show_earlier_messages.b6badd18"))
                    }
                    ForEach(rows) { item in
                        Group {
                            if item.id == model.signInGateRowID, model.savedCopy == nil,
                               let backend = model.backend(for: chat.backend) {
                                ChatAgentSetupCard(model: model, backend: backend, running: model.busy,
                                                   recoveryFailureID: model.signInFailureID)
                            } else {
                                ClientChatEventRow(
                                    item: item,
                                    attachmentData: attachmentData(for: item),
                                    defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                                    agentLabel: { backend in
                                        model.backend(for: backend)?.label ?? backend.capitalized
                                    },
                                    isPending: pendingApproval(item),
                                    resolve: { approval, choice in
                                        let owner = model.currentReference
                                        Task { await model.resolve(approval, choice: choice, owner: owner) }
                                    },
                                    attachmentIsLoading: model.loadingResponseAttachments.contains(attachmentID(for: item)),
                                    attachmentError: model.responseAttachmentErrors[attachmentID(for: item)],
                                    downloadAttachment: { attachment in
                                        Task { await model.downloadResponseAttachment(attachment) }
                                    },
                                    openAttachment: open(_:data:),
                                    faceSeed: model.faceSeed,
                                    isLive: !model.isShowingCachedTranscript && model.busy && item.id == model.transcriptItems.last?.id,
                                    animatesRunning: !model.isShowingCachedTranscript && item.id == spinning,
                                    expandsOutput: detail.level == .detailed,
                                    compactTools: detail.level == .minimal,
                                    toggleGroup: {
                                        beginViewportChoice()
                                        model.toggleGroup($0)
                                    },
                                    answerQuestion: { question, text in
                                        Task { await model.answerQuestion(question, answer: text) }
                                    },
                                    answeringQuestion: model.answeringQuestions.contains(item.questionID ?? ""),
                                    canAnswerQuestions: model.savedCopy == nil && !model.isShowingCachedTranscript,
                                    reviewChanges: folder != nil && model.savedCopy == nil ? { _ in reviewingChanges = true } : nil
                                )
                                .equatable()
                            }
                        }
                        // No geometry readers mid-fling: each one reports per
                        // frame, and a fast scroll turns those reports into a
                        // transaction per frame that placement never drains.
                        // Readers return 0.35s after the last moved frame, via
                        // `scrolling`, before any paging decision needs them.
                        // Also wherever the reader has stopped above the
                        // latest turn: that place is worth keeping. Never
                        // mid-scroll, which is a report per row per frame.
                        .clientTranscriptRowFrame(
                            item.id,
                            watched: (!follow.scrolling || (follow.settling && !follow.pinned))
                                && ((model.hasEarlier && measuringRows) || !follow.atEnd),
                            holdingReading: preservesReadingMark
                        )
                    }
                    if sliceOffset == 0 {
                        if !model.isShowingCachedTranscript, let mood = liveMood {
                            ChatWorkingIndicator(
                                seed: model.faceSeed,
                                mood: mood,
                                step: TranscriptFollow.liveStep(model.transcriptItems)
                            )
                        }
                        TranscriptBottomSentinel()
                    }
                }
                // Empty space still takes taps so a short transcript can hide
                // the keyboard, not only a fling on a long one.
                .contentShape(Rectangle())
                // One gate for the whole stack, not one per row: hit testing
                // sleeps mid-fling and wakes 0.35s after the last moved frame.
                // The pill rides outside this stack and never loses taps.
                .allowsHitTesting(!follow.scrolling && !model.isShowingCachedTranscript)
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)
                .chatScrollContent()
                .background {
                    GeometryReader { geometry in
                        ClientTranscriptScrollReporter(access: scrollAccess)
                            .preference(key: ClientTranscriptReadingFramesKey.self,
                                value: ClientTranscriptReadingGeometry(globalFrame: geometry.frame(in: .global)))
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            // No tap-to-dismiss gesture here: `.scrollDismissesKeyboard`
            // already hides the keyboard on scroll, and a transcript-wide
            // tap gate fires on attachment taps, link taps and text
            // selection too.
            // Leave the bottom scroll-edge effect in place. The composer
            // sits on a `safeAreaBar`, and that glass is what the fade is
            // for. Hiding it left a grey slab in the home indicator.
            // Cover the build-up, do not hide the stack. Opacity 0 is how a
            // lazy stack skipped measuring the last prompt until a later
            // layout (leave and come back) forced the real height.
            .overlay {
                if showsSkeleton {
                    TranscriptSkeleton()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: transcriptReady)
            .modifier(OpeningCover(
                isOpening: model.openingConversation || hasPendingViewport,
                ready: transcriptReady,
                conversationID: model.selected?.id,
                opening: $opening
            ))
            .chatScrollMetrics { metrics in
                guard isActive, follow.active else { return }
                if scrollAccess.readerIsMoving {
                    if readingFrames.captureReady || !readerMoved {
                        readingFrames.cancelCapture()
                        stopHoldingViewport()
                    }
                    if !readerMoved { readerMoved = true }
                }
                #if DEBUG
                TranscriptProbe.shared.noteMetrics()
                TranscriptProbe.shared.pinned = follow.pinned
                TranscriptProbe.shared.scrolling = follow.scrolling
                TranscriptProbe.shared.built = visibleItems.count
                #endif
                // The slice flag first: note() treats a hidden newest as
                // far from the end. Then the pin, then the window, which
                // has to see that decision on the same frame.
                follow.sliceHidesNewest = sliceOffset > 0
                follow.note(metrics)
                window.followingEnd = (follow.pinned || follow.settling) && sliceOffset == 0
                window.note(metrics)
            }
            .modifier(ClientTranscriptReadingGesture {
                guard isActive, follow.active else { return }
                readingFrames.cancelCapture()
                stopHoldingViewport()
                readerMoved = true
            })
            .transcriptFollowBar {
                if model.approvals.isEmpty && (follow.showJump || model.busy) {
                    TranscriptFollowPill(
                        showJump: follow.showJump,
                        busy: model.busy,
                        paused: follow.paused,
                        resume: {
                            showNewest()
                            resumeLatest()
                            Task { await returnToLatest(proxy) }
                        },
                        pause: { follow.pause() }
                    )
                }
            }
            .transcriptEarlierPages(model, window: window, proxy: proxy)
            .onPreferenceChange(ClientTranscriptReadingFramesKey.self) { geometry in
                readingFrames.replace(geometry)
                scrollAccess.refreshAttachment()
                keepViewport()
                holdViewport(proxy)
            }
            .onChange(of: structureToken) { _, _ in
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: followPulse) { _, _ in
                showNewest()
                resumeLatest()
                Task { await chaseLatest(proxy) }
            }
            .onChange(of: chat.running) { _, _ in
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: model.busy) { was, now in
                settleAfterTurn(was: was, now: now)
                if was, !now {
                    Task { await model.drainQueue() }
                }
            }
            .onChange(of: model.approvals.isEmpty) { _, empty in
                follow.suppressed = !empty
            }
            // A scroll that has come to rest is a reader who has stopped
            // somewhere. Wait a beat for the rows to say where they are:
            // they report on the update this change itself causes.
            .onChange(of: follow.scrolling) { _, moving in
                readingFrames.cancelCapture()
                guard !moving, isActive, follow.active else { return }
                captureReadingAfterQuiet()
            }
            .onChange(of: detail.level) { _, _ in
                beginViewportChoice()
            }
            // A request that arrives mid-stream would otherwise be pushed off
            // a short viewport before anybody saw it.
            .onChange(of: model.approvals.first?.id) { _, id in
                guard let id else { return }
                scrollTo("approval-\(id)", proxy, animated: true)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                scrollTo(target, proxy, animated: true)
                scrollTarget = nil
            }
            .onChange(of: model.transcriptItems.count, initial: true) { _, _ in
                follow.sliceHidesNewest = sliceOffset > 0
                #if DEBUG
                TranscriptProbe.shared.rows = model.transcriptItems.count
                TranscriptProbe.shared.built = visibleItems.count
                #endif
            }
            #if DEBUG
            .onAppear {
                TranscriptProbe.shared.install()
                TranscriptProbe.shared.rows = model.transcriptItems.count
                TranscriptProbe.shared.built = visibleItems.count
            }
            #endif
            .onAppear {
                follow.active = isActive
                follow.suppressed = !model.approvals.isEmpty
                window.nearTopChanged = { measuringRows = $0 }
                installRepin(proxy)
                scrollAccess.refreshAttachment(retryVisibility: true)
                guard isActive else { return }
                if model.viewportContinuity.mark(generation: model.selectionGeneration) != nil {
                    follow.stopFollowing()
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    follow.active = true
                    scrollAccess.refreshAttachment(retryVisibility: true)
                }
                else {
                    traceViewport("hidden")
                    retireViewport()
                    follow.freeze()
                }
            }
            .task(id: ClientChatViewportTaskIdentity(
                presentation: ChatPresentationIdentity(reading: model.readingIdentity, active: isActive),
                attachment: scrollAccess.attachmentIdentity, sceneActive: scenePhase == .active,
                vacancy: model.viewportContinuity.vacancy)) {
                // A lazy stack does not know its own height until it has drawn
                // the rows, so the first scroll to the end lands on estimates.
                // Hold the end across the frames the real heights take to
                // arrive: every one of those says the end is far below, and
                // believing one is how a long chat opened in its middle.
                guard !Task.isCancelled, isActive, follow.active, scenePhase == .active,
                      let attachment = scrollAccess.attachmentIdentity,
                      scrollAccess.matches(attachment) else {
                    if !isActive || !follow.active || scenePhase != .active || !scrollAccess.isEligible {
                        retireViewport()
                    }
                    return
                }
                viewportPlaced = false
                readerMoved = false
                readingFrames.cancelCapture()
                stopHoldingViewport()
                let generation = model.selectionGeneration
                let reference = model.currentReference
                let ticket = UUID()
                settleTaskID = ticket
                guard model.viewportContinuity.beginPlacement(generation: generation, owner: presenceOwner,
                    eligible: scrollAccess.matches(attachment)) else { return }
                let kept = model.viewportContinuity.mark(generation: generation)
                traceViewport("begin", mark: kept)
                var measurementCompleted = true
                if kept != nil { follow.stopFollowing() }
                follow.settle(true)
                if kept != nil { follow.pinned = false }
                window.followingEnd = kept == nil
                if kept == nil {
                    showNewest()
                    pinToLatest(proxy, animated: false)
                }
                defer {
                    if settleTaskID == ticket {
                        follow.settle(false)
                        if !Task.isCancelled, isActive, follow.active,
                           scenePhase == .active, scrollAccess.matches(attachment),
                           generation == model.selectionGeneration,
                           reference == model.currentReference,
                           model.viewportContinuity.owns(generation: generation, owner: presenceOwner) {
                            if measurementCompleted {
                                model.viewportContinuity.completePlacement(generation: generation, owner: presenceOwner)
                            }
                            viewportPlaced = true
                            holdViewport(proxy)
                        }
                    }
                }
                // Fetch time does not spend the layout-settling budget. Slow
                // hosts used to exhaust every correction before rows arrived.
                while model.openingConversation {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, isActive, follow.active,
                          scenePhase == .active, scrollAccess.matches(attachment),
                          reference == model.currentReference,
                          model.viewportContinuity.canPlace(generation: generation, currentGeneration: model.selectionGeneration, owner: presenceOwner,
                              ticket: ticket, currentTicket: settleTaskID) else { return }
                }
                guard !Task.isCancelled, isActive, follow.active,
                      scenePhase == .active, scrollAccess.matches(attachment),
                      reference == model.currentReference,
                      model.viewportContinuity.canPlace(generation: generation, currentGeneration: model.selectionGeneration, owner: presenceOwner,
                          ticket: ticket, currentTicket: settleTaskID) else { return }
                let restored = await restoreReadingPlace(proxy, attachment: attachment)
                if restored == .unmeasured { measurementCompleted = false; return }
                if restored != .unavailable { return }
                guard !Task.isCancelled, isActive, follow.active,
                      scenePhase == .active, scrollAccess.matches(attachment),
                      model.viewportContinuity.canPlace(generation: generation, currentGeneration: model.selectionGeneration, owner: presenceOwner,
                          ticket: ticket, currentTicket: settleTaskID) else { return }
                model.viewportContinuity.record(.latest, generation: generation, owner: presenceOwner)
                follow.jump()
                showNewest()
                // Same as the Mac: hold the end until the conversation has
                // stopped arriving, not for a fixed count of frames.
                var quiet = 0
                var correctionPins = 0
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, isActive, follow.active, !follow.abandoned,
                          scenePhase == .active, scrollAccess.matches(attachment),
                          reference == model.currentReference,
                          model.viewportContinuity.canPlace(generation: generation, currentGeneration: model.selectionGeneration, owner: presenceOwner,
                              ticket: ticket, currentTicket: settleTaskID) else { return }
                    // A lazy-stack scroll walks every row between here and
                    // the end. Limit settling corrections; geometry-based
                    // repinning handles later height changes.
                    if !follow.atEnd, correctionPins < 8 {
                        correctionPins += 1
                        pinToLatest(proxy, animated: false)
                    }
                    quiet = model.openingConversation ? 0 : quiet + 1
                    if follow.arrived, quiet >= 3 { return }
                }
            }
            .task(id: settleMood) {
                guard settleMood == .ok else { return }
                try? await Task.sleep(for: .milliseconds(480))
                settleMood = nil
            }
        }
    }

    /// Stage the bytes under the file's real name and hand them to Quick
    /// Look, which plays video, renders text and PDF, shows images, and
    /// carries the share sheet that Save to Files lives in.
    ///
    /// Staging every time rather than once: the copy sits in a cache that is
    /// pruned on a budget, so the one made when the row first appeared may
    /// well be gone by the time somebody taps it.
    private func open(_ attachment: ChatAttachment, data: Data) {
        do {
            let url = try ChatFileStaging.stage(data, id: attachment.id, name: attachment.name)
            previewFile = ChatPreviewedFile(id: attachment.id, url: url, name: attachment.name)
        } catch {
            // Never silent. A card that does nothing when tapped is the bug
            // this whole path is being rebuilt for.
            showDropNotice(L10n.text("apple.clientchatview.0_could_not_be_opened_1.3ad9cd09", "\(attachment.name)", "\(error.localizedDescription)"))
        }
    }

    private func attachmentID(for item: ChatDisplayItem) -> String {
        guard case let .attachment(attachment) = item.kind else { return "" }
        return attachment.id
    }

    private func attachmentData(for item: ChatDisplayItem) -> Data? {
        guard case let .attachment(attachment) = item.kind else { return nil }
        return model.responseAttachmentData[attachment.id]
    }

    private var setupSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let chat {
                        ChatSetupHeader(
                            model: model,
                            chat: chat,
                            collapsed: false,
                            showsIntro: false
                        )
                        ChatInstructionsCard(model: model, chat: chat)
                        ChatCostMeter(totals: model.turnUsage)
                        Button(L10n.text("apple.clientchatview.personas.fa2ea3fb"), .persona) { showingPersonas = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle(L10n.text("apple.clientchatview.chat_setup.9fa79d00"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.done"), .done) { showingSetup = false }
                }
            }
        }
        // Presented from this sheet, because the button that opens it is in
        // this sheet. Two `.sheet` modifiers on one view are not two
        // presentations: while the first is up the second is ignored, so
        // Personas did nothing until Done put the setup sheet away, and then
        // opened over the transcript. Done here comes back to setup. The
        // account sheet already learned this for its paywall.
        .sheet(isPresented: $showingPersonas) {
            PersonaEditor(model: model, onClose: { showingPersonas = false })
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }

    private var liveMood: PersonaMood? {
        TranscriptFollow.liveMood(
            items: model.transcriptItems,
            busy: model.busy,
            runningTool: model.isRunningTool,
            waiting: !model.approvals.isEmpty,
            settle: settleMood
        )
    }

    private var structureToken: String {
        TranscriptFollow.structureToken(
            items: model.transcriptItems,
            busy: model.busy,
            runningTool: model.isRunningTool,
            settle: settleMood
        )
    }

    private func settleAfterTurn(was: Bool, now: Bool) {
        if now {
            settleMood = nil
            return
        }
        guard was else { return }
        if case .failed = model.transcriptItems.last?.kind {
            settleMood = nil
        } else {
            settleMood = .ok
        }
    }

    private func pendingApproval(_ item: ChatDisplayItem) -> Bool {
        if case let .approval(approval) = item.kind {
            return model.approvals.contains { $0.id == approval.id }
        }
        return false
    }

    /// Whether the transcript may be looked at. Same rule as the Mac: the
    /// wireframe covers the frames between picking a conversation and the
    /// settle task starting, as well as the settle itself.
    /// Whether an opening is in progress for the conversation on screen.
    ///
    /// The wireframe covers an opening: the fetch, and the frames a lazy stack
    /// then spends measuring what the fetch delivered. Nothing else. A send, a
    /// jump and a streaming turn all reset `arrived` too, and an empty
    /// transcript never reaches it at all (`atEnd` needs a content height),
    /// so keying the cover on `arrived` alone put scaffolding over the first
    /// message of a new chat for the length of the settle budget.
    @State private var opening = false

    /// Whether the wireframe is up: an opening is under way, it has not
    /// settled, and no cached preview is standing in for it.
    private var showsSkeleton: Bool {
        hasPendingViewport || (opening && !transcriptReady && model.recentMessagePreview.isEmpty)
    }

    private var hasPendingViewport: Bool {
        !viewportPlaced && model.viewportContinuity.mark(generation: model.selectionGeneration) != nil
    }

    private var transcriptReady: Bool {
        !hasPendingViewport && follow.arrived && !model.openingConversation
    }


    /// Come back to the latest turn, by the cheapest route that works.
    ///
    /// The ForEach is a bounded slice, so scrolling it is cheap. Reopening
    /// still drops a host window grown by paging back, which is the memory
    /// and the event list, not the walk.
    private func returnToLatest(_ proxy: ScrollViewProxy) async {
        showNewest()
        if model.transcriptItems.count > TranscriptWindow.reopenAbove {
            await model.reopenAtLatest()
        }
        await chaseLatest(proxy)
    }

    /// Keep asking for the end until the view is actually there.
    ///
    /// One scroll is not enough from far away: a lazy stack answers on
    /// estimated heights and corrects them as it builds the rows in between.
    /// This stops as soon as the scroll callback reports the end steady, so
    /// a short hop costs two frames.
    private func chaseLatest(_ proxy: ScrollViewProxy) async {
        follow.chase(true)
        defer { follow.chase(false) }
        for _ in 0..<Self.chaseFrames {
            if !follow.atEnd { pinToLatest(proxy, animated: false) }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, !follow.abandoned else { return }
            if follow.steadyFrames >= 2 { return }
        }
    }

    /// How many frames one press of Jump to latest may spend arriving.
    private static let chaseFrames = 24

    /// Rows the transcript builds this pass. Same slice as the Mac.
    private var visibleItems: [ChatDisplayItem] {
        TranscriptSlice.items(model.transcriptItems, olderOffset: sliceOffset)
    }

    /// Rows above the built slice. Zero while the whole conversation fits.
    private var hiddenAboveCount: Int {
        TranscriptSlice.hiddenAbove(count: model.transcriptItems.count, olderOffset: sliceOffset)
    }

    /// `olderOffset` counted from the live end, or the offset that still
    /// starts on `sliceAnchor` after rows arrived above or below.
    private var sliceOffset: Int {
        if olderOffset > 0, let anchor = sliceAnchor {
            return TranscriptSlice.holding(anchor, in: model.transcriptItems, current: olderOffset)
        }
        return TranscriptSlice.clampOffset(olderOffset, count: model.transcriptItems.count)
    }

    private func showNewest() {
        applySlice(0)
    }

    private func revealEarlier() {
        follow.stopFollowing()
        applySlice(
            TranscriptSlice.revealingEarlier(
                count: model.transcriptItems.count, olderOffset: sliceOffset
            )
        )
    }

    /// Slide the built window and remember its first row so later inserts
    /// cannot replace what is on screen.
    private func applySlice(_ offset: Int) {
        let clamped = TranscriptSlice.clampOffset(offset, count: model.transcriptItems.count)
        olderOffset = clamped
        if clamped > 0 {
            sliceAnchor = TranscriptSlice.items(
                model.transcriptItems, olderOffset: clamped
            ).first?.id
            follow.sliceHidesNewest = true
        } else {
            sliceAnchor = nil
            follow.sliceHidesNewest = false
        }
    }

    /// Let the scroll callback put the viewport back on the end. Weak on the
    /// state, which owns the closure.
    private func installRepin(_ proxy: ScrollViewProxy) {
        let state = follow
        let model = model
        let access = scrollAccess
        let owner = presenceOwner
        state.repin = { [weak state, weak access] in
            guard let state, state.active, let access, access.isEligible,
                  model.viewportContinuity.owns(generation: model.selectionGeneration, owner: owner),
                  state.pinned, !state.sliceHidesNewest,
                  model.approvals.isEmpty else { return false }
            state.markDrivenInstant()
            proxy.scrollTo(TranscriptFollow.bottomID, anchor: .bottom)
            return true
        }
    }

    /// Whether a scroll to the end is the actual latest turn.
    ///
    /// The ForEach is a bounded slice, so walking it is cheap. A slice that
    /// has dropped the newest rows is not the end.
    private var canScrollToEnd: Bool { sliceOffset == 0 }

    private func pinToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // A pending request owns the view. Streaming text must not scroll it
        // out from under somebody who is reading it to decide.
        guard isActive, follow.active, scenePhase == .active, scrollAccess.isEligible,
              model.viewportContinuity.owns(generation: model.selectionGeneration, owner: presenceOwner),
              follow.pinned, model.approvals.isEmpty else { return }
        guard canScrollToEnd else {
            follow.stopFollowing()
            return
        }
        if !animated {
            let now = Date()
            guard now.timeIntervalSince(lastSilentPinAt) > 0.15 else { return }
            lastSilentPinAt = now
        }
        scrollTo(TranscriptFollow.bottomID, proxy, animated: animated)
    }

    private func resumeLatest() {
        navigation.chatHandoff.chooseViewport(model: model)
        settleTaskID = UUID()
        stopHoldingViewport()
        readerMoved = false
        readingFrames.cancelCapture()
        viewportPlaced = true
        model.viewportContinuity.chooseLatest(generation: model.selectionGeneration)
        if let reference = model.currentReference { ChatReadingStore.shared.requestLatest(for: reference) }
        model.viewportContinuity.completePlacement(generation: model.selectionGeneration, owner: presenceOwner)
        follow.settle(false)
        follow.jump()
    }

    private func keepViewport() {
        guard readingFrames.captureReady, readerMoved, isActive, follow.active, !follow.scrolling, !follow.settling,
              scenePhase == .active, let attachment = scrollAccess.attachmentIdentity, scrollAccess.matches(attachment),
              !scrollAccess.readerIsTouching,
              model.viewportContinuity.isPlaced(generation: model.selectionGeneration, owner: presenceOwner),
              !follow.pinned || follow.atEnd else { return }
        let position = readingPosition()
        traceViewport("sample", position: position)
        // A preference pass can arrive before the local native reporter.
        // Keep gesture permission until fresh geometry supplies a real row.
        guard position != .unknown else { return }
        TranscriptReading.record(position, for: model.currentReference)
        model.viewportContinuity.recordMeasurement(position,
            generation: model.selectionGeneration, owner: presenceOwner, readerInitiated: readerMoved)
        traceViewport("capture")
        readerMoved = false
        readingFrames.captureReady = false
    }

    /// A deliberate row jump or disclosure changes what the reader chose to
    /// see. Retire the old hold now; measure the new choice after it settles.
    private func beginViewportChoice() {
        guard isActive, follow.active,
              model.viewportContinuity.owns(generation: model.selectionGeneration, owner: presenceOwner) else { return }
        navigation.chatHandoff.chooseViewport(model: model)
        stopHoldingViewport()
        readingFrames.cancelCapture()
        settleTaskID = UUID()
        follow.settle(false)
        viewportPlaced = true
        readerMoved = true
        if let reference = model.currentReference {
            _ = ChatReadingStore.shared.takeRequest(for: reference)
        }
        model.viewportContinuity.record(.latest, generation: model.selectionGeneration, owner: presenceOwner)
        model.viewportContinuity.completePlacement(generation: model.selectionGeneration, owner: presenceOwner)
        captureReadingAfterQuiet()
    }

    private func captureReadingAfterQuiet() {
        guard let attachment = scrollAccess.attachmentIdentity, scrollAccess.matches(attachment) else { return }
        let reference = model.currentReference
        let generation = model.selectionGeneration
        let captureID = readingFrames.captureID
        Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, isActive, follow.active, !follow.scrolling, !follow.settling,
                  scrollAccess.matches(attachment),
                  !scrollAccess.readerIsTouching,
                  reference == model.currentReference,
                  generation == model.selectionGeneration, readerMoved,
                  captureID == readingFrames.captureID else { return }
            if viewportPlaced, model.viewportContinuity.owns(generation: generation, owner: presenceOwner) {
                model.viewportContinuity.completePlacement(generation: generation, owner: presenceOwner)
            }
            guard model.viewportContinuity.isPlaced(generation: generation, owner: presenceOwner) else { return }
            readingFrames.captureReady = true
            for _ in 0..<10 {
                guard !Task.isCancelled, isActive, follow.active, !follow.scrolling, !follow.settling,
                      scrollAccess.matches(attachment),
                      reference == model.currentReference,
                      generation == model.selectionGeneration,
                      captureID == readingFrames.captureID,
                      model.viewportContinuity.owns(generation: generation, owner: presenceOwner),
                      readingFrames.captureReady, readerMoved else { return }
                keepViewport()
                if !readerMoved { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func readingPosition() -> ChatReadingPosition {
        if follow.atEnd, follow.pinned { return .latest }
        guard let coordinates = scrollAccess.readingCoordinates(globalFrame: readingFrames.globalFrame) else { return .unknown }
        let anchor = ChatReadingPosition.anchor(in: readingFrames.frames,
            viewportHeight: Double(coordinates.visible.height),
            viewportTop: Double(coordinates.visible.minY), frameOffsetY: Double(coordinates.originY))
        return ChatReadingPosition.from(atEnd: follow.atEnd, pinned: follow.pinned,
            anchorID: anchor?.id, anchorTop: anchor?.top ?? 0, anchorHeight: anchor?.height ?? 0,
            viewportHeight: Double(coordinates.visible.height))
    }

    private var preservesReadingMark: Bool {
        isActive && follow.active && !readerMoved
            && model.viewportContinuity.owns(generation: model.selectionGeneration, owner: presenceOwner)
            && model.viewportContinuity.mark(generation: model.selectionGeneration) != nil
    }

    private func stopHoldingViewport() {
        readingDelivery.cancel()
        readingHold.reset()
    }

    private func retireViewport() {
        settleTaskID = UUID()
        stopHoldingViewport()
        readingFrames.cancelCapture()
        follow.settle(false)
        model.viewportContinuity.release(generation: model.selectionGeneration, owner: presenceOwner)
    }

    /// A layout can move an older row after placement has converged. Perform
    /// measured corrections after layout, with a fixed budget and no history
    /// writes. Reader input and explicit latest always take over immediately.
    private func holdViewport(_ proxy: ScrollViewProxy) {
        guard viewportPlaced, preservesReadingMark, !follow.settling,
              scenePhase == .active, let attachment = scrollAccess.attachmentIdentity, scrollAccess.matches(attachment),
              !scrollAccess.readerIsTouching,
              let reference = model.currentReference,
              let mark = model.viewportContinuity.mark(generation: model.selectionGeneration) else { return }
        let generation = model.selectionGeneration
        let ticket = settleTaskID
        readingDelivery.submit {
            guard viewportPlaced, preservesReadingMark, !follow.settling,
                  scenePhase == .active, scrollAccess.matches(attachment),
                  !scrollAccess.readerIsTouching,
                  generation == model.selectionGeneration, reference == model.currentReference,
                  ticket == settleTaskID,
                  model.viewportContinuity.mark(generation: generation) == mark,
                  let coordinates = scrollAccess.readingCoordinates(globalFrame: readingFrames.globalFrame) else { return }
            readingHold.prepare(mark: mark, viewport: coordinates.visible)
            guard readingHold.canCorrect else { return }
            let rows = model.transcriptItems
            let closedHeader = rows.first { row in
                guard case let .group(group) = row.kind else { return false }
                return !group.open && row.id == "g:\(mark.eventID)"
            }?.id
            guard let id = closedHeader ?? ChatReadingAnchor.resolve(mark.eventID, items: rows, events: model.events) else { return }
            // A native reflow can briefly report the end. Kept reading intent
            // owns this correction and suppresses any pending end repin.
            if follow.pinned { follow.stopFollowing() }
            if let frame = readingFrames.frames[id] {
                let result = scrollAccess.correct(mark, frame: frame,
                    globalFrame: readingFrames.globalFrame, follow: follow)
                if result == .placed { readingHold.corrected() }
                if result == .settled {
                    model.viewportContinuity.completePlacement(generation: generation, owner: presenceOwner)
                }
            } else if readingHold.takeReveal() {
                let point = UnitPoint(x: 0.5, y: mark.within > 0 ? 0 : min(max(mark.offset, 0), 0.6))
                placeRow(id, proxy, at: point)
            }
        }
    }

    private func traceViewport(_ event: String, mark: ChatReadingMark? = nil,
                               position: ChatReadingPosition? = nil) {
        #if DEBUG
        ClientViewportTrace.note(event,
            mark: mark ?? model.viewportContinuity.mark(generation: model.selectionGeneration),
            scroll: scrollAccess.view,
            details: "model=\(ObjectIdentifier(model)) chat=\(model.selected?.id ?? "none") workspace=\(model.workspaceID ?? "none") generation=\(model.selectionGeneration) owner=\(presenceOwner) stamp=\(readingFrames.stamp) frames=\(readingFrames.frames.count) coordinates=\(String(describing: scrollAccess.readingCoordinates(globalFrame: readingFrames.globalFrame))) sample=\(String(describing: position)) placed=\(model.viewportContinuity.isPlaced(generation: model.selectionGeneration, owner: presenceOwner)) reader=\(readerMoved) pinned=\(follow.pinned) settling=\(follow.settling)")
        #endif
    }

    /// Explicit navigation wins. Otherwise only the same live selection may
    /// resume its viewport; passive history never moves a new selection.
    private func restoreReadingPlace(_ proxy: ScrollViewProxy, attachment: ChatViewportAttachmentIdentity) async -> TranscriptReading.Restoration {
        guard scenePhase == .active, scrollAccess.matches(attachment),
              model.viewportContinuity.owns(generation: model.selectionGeneration, owner: presenceOwner),
              let reference = model.currentReference,
              let mark = ChatReadingStore.shared.takeRequest(for: reference)
                ?? model.viewportContinuity.mark(generation: model.selectionGeneration) else { return .unavailable }
        // Keep explicit navigation before the first await, so a cancelled
        // presentation hands the same requested row to its successor.
        model.viewportContinuity.record(.away(mark), generation: model.selectionGeneration, owner: presenceOwner)
        traceViewport("restore", mark: mark)
        let generation = model.selectionGeneration
        let ticket = settleTaskID
        var lastFrameStamp = readingFrames.stamp
        return await TranscriptReading.restore(mark, reference: reference, model: model, follow: follow,
            isCurrent: {
                generation == model.selectionGeneration && reference == model.currentReference
                    && scenePhase == .active && scrollAccess.matches(attachment)
                    && ticket == settleTaskID
                    && model.viewportContinuity.owns(generation: generation, owner: presenceOwner)
                    && model.viewportContinuity.mark(generation: generation) == mark
            },
            correct: { id, mark in
                guard isActive, follow.active, !Task.isCancelled,
                      scenePhase == .active, scrollAccess.matches(attachment),
                      generation == model.selectionGeneration, reference == model.currentReference,
                      ticket == settleTaskID,
                      model.viewportContinuity.owns(generation: generation, owner: presenceOwner) else { return .interrupted }
                guard readingFrames.stamp != lastFrameStamp,
                      let frame = readingFrames.frames[id] else { return .unavailable }
                let result = scrollAccess.correct(mark, frame: frame, globalFrame: readingFrames.globalFrame, follow: follow)
                if result == .placed { lastFrameStamp = readingFrames.stamp }
                return result
            }) { id, point in
            lastFrameStamp = readingFrames.stamp
            placeRow(id, proxy, at: point)
        }
    }

    /// Put one row where the reader had it, with the rest of the conversation
    /// below it and the earlier part one button above.
    private func placeRow(_ id: String, _ proxy: ScrollViewProxy, at point: UnitPoint) {
        guard isActive, follow.active, scenePhase == .active, scrollAccess.isEligible,
              model.viewportContinuity.owns(generation: model.selectionGeneration, owner: presenceOwner) else { return }
        applySlice(TranscriptSlice.holding(id, in: model.transcriptItems, current: 0))
        follow.markDrivenInstant()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: point)
        }
    }

    private func scrollTo(_ id: String, _ proxy: ScrollViewProxy, animated: Bool) {
        guard isActive, follow.active, scenePhase == .active, scrollAccess.isEligible,
              model.viewportContinuity.owns(generation: model.selectionGeneration, owner: presenceOwner) else { return }
        // Every scroll here is programmatic. Say so, or the frames of the
        // animation read as the reader leaving and unpin mid-flight.
        // Instant pins land on the same frame and only need a short window.
        // The end always exists. Anything else may sit outside the built
        // slice: slide to it first, or the scroll lands nowhere.
        if id != TranscriptFollow.bottomID {
            beginViewportChoice()
            // A target folded into a step group opens it first.
            model.revealRow(id)
            applySlice(TranscriptSlice.revealing(id, in: model.transcriptItems))
        } else {
            showNewest()
        }
        let animate = animated && !reduceMotion
        #if DEBUG
        TranscriptProbe.shared.noteScroll(id == TranscriptFollow.bottomID ? "pin" : "row")
        #endif
        follow.markDriven(duration: animate ? 0.4 : 0.08)
        if !animate {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: TranscriptFollow.structureDuration)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func submit(from chat: ChatConversation, sendNow: Bool = false) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attached image is content on its own: text is only mandatory
        // when there is nothing attached.
        guard !text.isEmpty || !model.attachments.isEmpty, !model.sending else { return }
        switch model.holdForSignIn(text, backend: chat.backend) {
        case .notNeeded: break
        case .refused: return
        case .held:
            showNewest()
            resumeLatest()
            followPulse += 1
            return
        }
        // Enqueue first: a full queue reports an error and returns nil, and
        // the words must survive that path rather than being wiped.
        if sendNow {
            guard let item = model.enqueue(text, atFront: true) else { return }
            model.clearDraft()
            // Sending is engaging: follow is the default, so a new turn resumes
            // it even if it was paused before. Pausing again is one tap. Hide the
            // keyboard and snap to the end so the next tokens are not off-screen
            // above a closed keyboard.
            showNewest()
            resumeLatest()
            followPulse += 1
            let queueOwner = model.currentReference
            Task { await model.sendNow(item, owner: queueOwner) }
            return
        }
        if model.busy {
            switch model.beginBusyNote(text) {
            case .queue:
                guard model.enqueue(text) != nil else { return }
                model.clearDraft()
                showNewest()
                resumeLatest()
                followPulse += 1
                return
            case .steering(let token):
                showNewest()
                resumeLatest()
                followPulse += 1
                Task {
                    await model.finishBusyNote(token)
                }
                return
            }
        }
        // The composer empties, the stored copy does not: it is dropped when
        // the host has the words and put back when it refuses them.
        guard model.holdDraftForSending(text) else { return }
        showNewest()
        resumeLatest()
        followPulse += 1
        Task { await model.sendFromComposer() }
    }

    private var dropExperienceVisible: Bool {
        urlDropTargeted || textDropTargeted || dataDropTargeted || composerDropTargeted
    }

    private func receive(_ drops: [ChatInboxDrop]) {
        guard let owner = model.currentReference else { return }
        Task { await receive(drops, owner: owner) }
    }

    private func receive(_ drops: [ChatInboxDrop], owner: WorkReference) async {
        for drop in drops {
            switch drop {
            case let .attachment(item):
                await model.attach(item, to: owner)
            case let .text(text):
                model.appendImportedText(text, to: owner)
            case .folder:
                showDropNotice(L10n.text("apple.clientchatview.attach_files_not_folders.9039f9a4"))
            }
        }
    }

    private func showDropNotice(_ message: String) {
        dropNoticeGeneration += 1
        let generation = dropNoticeGeneration
        dropNotice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard dropNoticeGeneration == generation else { return }
            dropNotice = nil
        }
    }
}

/// A weak reference to this transcript's own scroll view. Row placement uses
/// its measured geometry after SwiftUI has revealed the target lazy row.
private struct ClientChatViewportTaskIdentity: Hashable {
    let presentation: ChatPresentationIdentity
    let attachment: ChatViewportAttachmentIdentity?
    let sceneActive: Bool
    let vacancy: UInt64
}

@MainActor
private final class ClientTranscriptScrollAccess {
    private(set) weak var view: UIScrollView?
    private(set) weak var reporter: UIView?
    private let attachment = ChatViewportAttachment()
    private var reporterID: UUID?
    private var retiredReporterID: UUID?
    private var publicationQueued = false
    private var readinessTask: Task<Void, Never>?
    private var readinessTaskID: UUID?
    private var readinessSource: ChatViewportAttachmentIdentity?

    var attachmentIdentity: ChatViewportAttachmentIdentity? { attachment.identity }
    var isEligible: Bool { liveAttachmentIdentity != nil }
    func matches(_ identity: ChatViewportAttachmentIdentity) -> Bool { liveAttachmentIdentity == identity }

    private var liveAttachmentIdentity: ChatViewportAttachmentIdentity? {
        guard let identity = sourceIdentity, let view, let window = view.window, let reporter,
              window.windowScene?.activationState == .foregroundActive else { return nil }
        var ancestor: UIView? = reporter
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return nil }
            ancestor = current.superview
        }
        let usable = view.convert(view.bounds.inset(by: view.adjustedContentInset), to: window)
        guard ChatViewportAttachment.isVisible(usable: usable, window: window.bounds,
                                              ancestorsVisible: true) else { return nil }
        return identity
    }

    private var sourceIdentity: ChatViewportAttachmentIdentity? {
        guard let view, let window = view.window, let reporter, let reporterID,
              reporter.window === window else { return nil }
        return ChatViewportAttachmentIdentity(reporter: reporterID,
            scroll: ObjectIdentifier(view), window: ObjectIdentifier(window))
    }

    func bind(reporter: UIView, id: UUID) {
        if self.reporter !== reporter {
            cancelReadiness()
            self.reporter = reporter
            reporterID = id
            attachment.register(reporter: id)
        }
        refreshAttachment()
    }

    func refreshAttachment(retryVisibility: Bool = false, from source: UIView? = nil) {
        if let source, source !== reporter { return }
        var ancestor = reporter?.superview
        var scroll: UIScrollView?
        while let current = ancestor {
            if let found = current as? UIScrollView { scroll = found; break }
            ancestor = current.superview
        }
        view = reporter?.window != nil && reporter?.window === scroll?.window ? scroll : nil
        if retryVisibility || readinessSource != sourceIdentity { cancelReadiness() }
        if retryVisibility { attachment.resetReadiness() }
        if liveAttachmentIdentity != nil {
            cancelReadiness()
            attachment.resetReadiness()
        }
        startReadinessIfNeeded()
        queuePublication()
    }

    func retire(reporter: UIView) {
        guard self.reporter === reporter else { return }
        cancelReadiness()
        retiredReporterID = reporterID
        reporterID = nil
        self.reporter = nil
        view = nil
        queuePublication()
    }

    private func cancelReadiness() {
        readinessTask?.cancel()
        if let ticket = readinessTaskID { attachment.finishReadiness(ticket: ticket) }
        readinessTask = nil
        readinessTaskID = nil
        readinessSource = nil
    }

    /// A fade can become visible without new geometry. Probe only this
    /// attached instance for a bounded episode; hidden layout frames cannot
    /// keep replenishing its budget.
    private func startReadinessIfNeeded() {
        guard readinessTask == nil, liveAttachmentIdentity == nil, let identity = sourceIdentity,
              view?.window?.windowScene?.activationState == .foregroundActive,
              let ticket = attachment.beginReadiness(identity) else { return }
        readinessTaskID = ticket
        readinessSource = identity
        readinessTask = Task { [weak self] in
            defer {
                if self?.readinessTaskID == ticket, self?.attachment.finishReadiness(ticket: ticket) == true {
                    self?.readinessTask = nil
                    self?.readinessTaskID = nil
                    self?.readinessSource = nil
                }
            }
            for _ in 0..<12 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled, self.readinessTaskID == ticket,
                      self.sourceIdentity == identity,
                      self.view?.window?.windowScene?.activationState == .foregroundActive,
                      self.attachment.takeReadinessAttempt(identity, ticket: ticket) else { return }
                self.refreshAttachment()
                if self.liveAttachmentIdentity != nil { return }
            }
        }
    }

    /// Publish after UIKit/SwiftUI finish their update. Re-evaluate the current
    /// reporter then, so queued teardown cannot resurrect a predecessor.
    private func queuePublication() {
        guard !publicationQueued else { return }
        publicationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publicationQueued = false
            if let reporterID = self.reporterID {
                let identity = self.liveAttachmentIdentity
                if identity != nil {
                    self.cancelReadiness()
                    self.attachment.resetReadiness()
                }
                self.attachment.publish(identity, reporter: reporterID)
            } else if let retired = self.retiredReporterID {
                self.attachment.retire(reporter: retired)
            }
            self.retiredReporterID = nil
        }
    }

    /// SwiftUI global coordinates belong to its hierarchy root. Calibrate
    /// that root against this reporter's own window, including in a sheet
    /// or split column. No scene or window lookup is needed.
    func readingCoordinates(globalFrame: CGRect?) -> (visible: CGRect, originY: CGFloat)? {
        guard isEligible, let view, let window = view.window, let reporter,
              reporter.window === window, let global = globalFrame else { return nil }
        let native = reporter.convert(reporter.bounds, to: window)
        let visible = view.convert(view.bounds.inset(by: view.adjustedContentInset), to: window)
        guard visible.height > 0, visible.minY.isFinite, native.minY.isFinite,
              global.minY.isFinite else { return nil }
        return (visible, native.minY - global.minY)
    }

    var readerIsMoving: Bool {
        guard let view else { return false }
        return view.isDragging || view.isDecelerating
    }

    var readerIsTouching: Bool {
        guard let view else { return false }
        return view.isTracking || view.isDragging || view.isDecelerating
    }

    func correct(_ mark: ChatReadingMark, frame: CGRect, globalFrame: CGRect?, follow: TranscriptFollowState)
        -> TranscriptReading.MeasuredPlacement {
        guard let view, let coordinates = readingCoordinates(globalFrame: globalFrame) else { return .unavailable }
        guard !view.isTracking, !view.isDragging, !view.isDecelerating else { return .interrupted }
        #if DEBUG
        ClientViewportTrace.note("correct", mark: mark, scroll: view, frame: frame,
            details: "visible=\(coordinates.visible) originY=\(coordinates.originY)")
        #endif
        guard let delta = ChatReadingPosition.correction(for: mark,
            rowTop: Double(frame.minY + coordinates.originY - coordinates.visible.minY),
            rowHeight: Double(frame.height),
            viewportHeight: Double(coordinates.visible.height)) else { return .unavailable }
        let minimum = -view.adjustedContentInset.top
        let maximum = max(minimum, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        let offset = min(max(view.contentOffset.y + CGFloat(delta), minimum), maximum)
        if abs(offset - view.contentOffset.y) <= 0.5 { return .settled }
        follow.markDrivenInstant()
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: offset), animated: false)
        return .placed
    }
}

/// Paging owns its named-coordinate dictionary and may clear it. Reading
/// measurements belong to this presentation and never invalidate the body.
@MainActor
private final class ClientTranscriptReadingFrames {
    var frames: [String: CGRect] = [:]
    var globalFrame: CGRect?
    var stamp: UInt64 = 0
    var captureReady = false
    var captureID = UUID()
    func cancelCapture() {
        captureReady = false
        captureID = UUID()
    }
    func replace(_ geometry: ClientTranscriptReadingGeometry) {
        frames = geometry.frames
        globalFrame = geometry.globalFrame
        stamp &+= 1
    }
}

private struct ClientTranscriptReadingGeometry: Equatable {
    var frames: [String: CGRect] = [:]
    var globalFrame: CGRect?
}

private struct ClientTranscriptReadingFramesKey: PreferenceKey {
    static let defaultValue = ClientTranscriptReadingGeometry()
    static func reduce(value: inout ClientTranscriptReadingGeometry, nextValue: () -> ClientTranscriptReadingGeometry) {
        let next = nextValue()
        value.frames.merge(next.frames, uniquingKeysWith: { _, latest in latest })
        if let globalFrame = next.globalFrame { value.globalFrame = globalFrame }
    }
}

private extension View {
    func clientTranscriptRowFrame(_ id: String, watched: Bool, holdingReading: Bool) -> some View {
        background {
            if watched || holdingReading {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: TranscriptRowFrameKey.self,
                            value: watched ? [id: geometry.frame(in: .named(TranscriptFollow.spaceName))] : [:])
                        .preference(key: ClientTranscriptReadingFramesKey.self,
                            value: ClientTranscriptReadingGeometry(frames: [id: geometry.frame(in: .global)]))
                }
            }
        }
    }
}

private struct ClientTranscriptReadingGesture: ViewModifier {
    let moved: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { moved() }
            }
        } else {
            content
        }
    }
}

#if DEBUG
@MainActor
private enum ClientViewportTrace {
    private static let enabled = ProcessInfo.processInfo.environment["TOKENSTAT_VIEWPORT_TRACE"] == "1"
    static func note(_ event: String, mark: ChatReadingMark? = nil, scroll: UIScrollView? = nil,
                     frame: CGRect? = nil, details: String = "") {
        guard enabled else { return }
        let place = mark.map { "row=\($0.eventID) offset=\($0.offset) within=\($0.within)" } ?? "latest"
        let geometry = scroll.map {
            "offset=\($0.contentOffset) bounds=\($0.bounds) insets=\($0.adjustedContentInset) content=\($0.contentSize)"
        } ?? "no-scroll"
        print("chat-viewport \(event) \(place) frame=\(String(describing: frame)) \(geometry) \(details)")
    }
}
#endif

private struct ClientTranscriptScrollReporter: UIViewRepresentable {
    let access: ClientTranscriptScrollAccess

    func makeUIView(context: Context) -> Reporter {
        let view = Reporter()
        view.isUserInteractionEnabled = false
        view.access = access
        access.bind(reporter: view, id: view.id)
        return view
    }

    func updateUIView(_ view: Reporter, context: Context) {
        view.access = access
        access.bind(reporter: view, id: view.id)
    }

    static func dismantleUIView(_ view: Reporter, coordinator: ()) {
        view.access?.retire(reporter: view)
        view.access = nil
    }

    final class Reporter: UIView {
        let id = UUID()
        weak var access: ClientTranscriptScrollAccess?
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            report()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }
        private func report() {
            access?.refreshAttachment(from: self)
        }
    }
}

#endif
