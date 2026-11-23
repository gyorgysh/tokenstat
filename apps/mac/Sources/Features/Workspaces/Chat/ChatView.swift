// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import OSLog
import SwiftUI
#if os(macOS)
import AppKit
#endif

private struct ChatConversationOverview: View {
    @Bindable var model: ChatModel
    let workspaceID: String
    var workspaceName: String?
    var onOpen: (ChatConversation) -> Void
    var onNew: () -> Void
    @State private var search = ""
    @State private var backend = ""
    @State private var runningOnly = false
    @State private var alphabetical = false
    @State private var pendingRemoval: ChatConversation?

    private var conversations: [ChatConversation] {
        model.folderID == workspaceID ? model.chats : []
    }

    private func agentName(_ id: String) -> String {
        model.backends.first { $0.id == id }?.label ?? id
    }

    private var shown: [ChatConversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter {
            (backend.isEmpty || $0.backend == backend) && (!runningOnly || $0.running)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || agentName($0.backend).localizedCaseInsensitiveContains(query)
                    || ($0.model?.localizedCaseInsensitiveContains(query) ?? false))
        }.sorted {
            if alphabetical { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return ($0.lastMessageAtMs ?? $0.updatedAtMs) > ($1.lastMessageAtMs ?? $1.updatedAtMs)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(Theme.accent).font(Theme.font(22))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("apple.chatview.conversations.1d432f58")).font(Theme.font(24, weight: .semibold))
                        Text(L10n.text("apple.chatview.find_and_resume_work_in_0.3ebaee48", "\(workspaceName ?? L10n.text("apple.chatview.this_project.11453073"))"))
                            .font(Theme.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("apple.chatview.new_chat.db18382a"), .create, action: onNew).buttonStyle(AccentButtonStyle())
                        .disabled(model.isLoading || model.folderID != workspaceID)
                }
                if let error = model.error {
                    Text(error).font(Theme.callout).foregroundStyle(Theme.warning)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3), spacing: Theme.Space.s) {
                    ActivitySummaryTile(title: L10n.text("apple.chatview.conversations.1d432f58"), value: conversations.count, symbol: "bubble.left.and.bubble.right")
                    ActivitySummaryTile(title: L10n.text("common.running"), value: conversations.filter(\.running).count, symbol: "play.circle")
                    ActivitySummaryTile(title: L10n.text("apple.chatview.agents_used.9ba9cedc"), value: Set(conversations.map(\.backend)).count, symbol: "sparkles")
                }
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("apple.chatview.search_titles_agents_or_models.4795e797"), text: $search).textFieldStyle(.plain)
                }
                .padding(Theme.Space.s)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
                HStack(spacing: Theme.Space.m) {
                    Picker(L10n.text("apple.chatview.agent.11b39c93"), selection: $backend) {
                        Text(L10n.text("apple.chatview.all_agents.54c32d3e")).tag("")
                        ForEach(Set(conversations.map(\.backend)).sorted(), id: \.self) { id in
                            Text(agentName(id)).tag(id)
                        }
                    }.frame(maxWidth: 200)
                    Toggle(L10n.text("apple.chatview.running_only.48bbf789"), isOn: $runningOnly).toggleStyle(.button)
                    Spacer(minLength: 0)
                    Picker(L10n.text("apple.chatview.sort.bec69036"), selection: $alphabetical) {
                        Text(L10n.text("apple.chatview.recent_first.e23e162b")).tag(false)
                        Text(L10n.text("apple.chatview.title_a_z.ab217de6")).tag(true)
                    }.labelsHidden().frame(width: 145)
                }
                if model.isLoading || model.folderID != workspaceID {
                    Skeleton.CardStack(rows: 3)
                } else if conversations.isEmpty {
                    ContentUnavailableView(L10n.text("apple.chatview.no_conversations_yet.0d60084f"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("apple.chatview.start_a_chat_to_work_with_an_agent_in_this.1a00be4f")))
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else if shown.isEmpty {
                    ContentUnavailableView(L10n.text("apple.chatview.no_matching_conversations.8a36372a"), systemImage: "magnifyingglass", description: Text(L10n.text("apple.chatview.try_another_search_or_adjust_the_filters.cbfdef66")))
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else {
                    Text(L10n.text("apple.chatview.0_conversations.c8fbf1b4", "\(shown.count)")).font(Theme.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: Theme.Space.s) {
                        ForEach(shown) { conversation in
                            Button { onOpen(conversation) } label: {
                                HStack(spacing: Theme.Space.m) {
                                    HarnessMark(id: conversation.backend, size: 40)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(conversation.title.isEmpty ? L10n.text("apple.chatview.untitled_conversation.31d248c4") : conversation.title)
                                            .font(Theme.font(14, weight: .semibold)).lineLimit(2)
                                        HStack(spacing: Theme.Space.s) {
                                            Text(agentName(conversation.backend)).foregroundStyle(Theme.accent)
                                            if let name = conversation.model, !name.isEmpty { Text(name).lineLimit(1) }
                                            if conversation.running { Label(L10n.text("common.running"), systemImage: "play.fill").foregroundStyle(Theme.secondary) }
                                        }.font(Theme.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: Theme.Space.s)
                                    RelativeTimeText(date: Date(timeIntervalSince1970: Double(conversation.lastMessageAtMs ?? conversation.updatedAtMs) / 1000), unitsStyle: .short)
                                        .font(Theme.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(.tertiary)
                                }
                                .padding(Theme.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                                .contentShape(Rectangle())
                            }.buttonStyle(CardButtonStyle())
                            #if os(macOS)
                            .modifier(ConversationPreviewHover {
                                await model.warmConversationPreview(conversation, in: workspaceID)
                            })
                            #endif
                            .contextMenu {
                                Button(L10n.text("apple.chatview.remove_chat.4e6c56bb"), .delete, role: .destructive) {
                                    pendingRemoval = conversation
                                }
                            }
                        }
                    }
                }
            }.padding(Theme.Space.m)
        }
        .background(Theme.background)
        .confirmationDialog(
            L10n.text("apple.chatview.remove_this_chat.5fe93d92"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.chatview.remove_chat.4e6c56bb"), role: .destructive) {
                if let chat = pendingRemoval {
                    Task { await model.remove(chat, in: workspaceID) }
                }
                pendingRemoval = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(L10n.text("apple.chatview.this_permanently_deletes_the_transcript.470ca3e0"))
        }
        .onChange(of: workspaceID) { _, _ in
            search = ""
            backend = ""
            runningOnly = false
        }
    }
}

struct ChatView: View {
    @Bindable var model: ChatModel
    @State private var detail = ChatDetailPreference.shared
    let workspaceID: String
    var workspaceName: String? = nil
    /// The folder's git state, when it has one. Chat is not drawn inside the
    /// workspace surface, so it never inherited the header that carries the
    /// branch control, and a chat about a repository could not say which
    /// branch it was about or move to another one.
    var git: GitStatus? = nil
    /// Refresh the folder after a checkout, so the chip and everything else
    /// reading git agree about where the folder now is.
    var onBranchChanged: (() async -> Void)? = nil
    /// Opens the folder's changes beside the chat, at one file or all of
    /// them. Nil where this pane has no place to open them.
    var onReviewChanges: ((String?) -> Void)? = nil
    var onReviewTurnChanges: ((ChatTurnChanges, String?) -> Void)? = nil
    var onNewChat: (() -> Void)? = nil
    @Binding var showingOverview: Bool
    /// Whether this pane is the one in front.
    ///
    /// The Mac keeps it mounted behind other screens so a transcript and the
    /// place somebody had read to survive a trip to Insights and back. A pane
    /// nobody can see does not poll, and it does not hold the shared model to
    /// a folder that has since been left: it reloads when it comes forward.
    var isActive = true
    var loadsWorkspace = true
    var showsConversationToolbarActions = true
    /// The composer's words live on the model, keyed to the conversation
    /// rather than to this pane, so leaving and coming back finds them and
    /// switching conversations does not carry them across.
    @State private var draftSelection = NSRange(location: 0, length: 0)
    /// A row the transcript should jump to, set by the pending-approval bar.
    @State private var scrollTarget: String?
    @State private var follow = TranscriptFollowState()
    @State private var window = TranscriptWindow()
    @State private var settleMood: PersonaMood?
    @State private var settleTaskID = UUID()
    @State private var settledPresentation: ChatPresentationIdentity?
    /// Only a new conversation raises the opening cover.
    @State private var settledSelection: ChatReadingIdentity?
    /// Bumped on send so the transcript scrolls to the end synchronously,
    /// instead of waiting for the first streamed token to trigger a pin.
    @State private var followPulse = 0
    /// Last instant (non-animated) pin. A scrollTo on a lazy stack walks
    /// every row in between, so silent pins from the settle loop, structural
    /// changes, and pulses share one ~150ms gate, same as the growth repins.
    /// Animated pins (a jump, an approval card) always go through.
    @State private var lastSilentPinAt = Date.distantPast
    // The boundary between eager and lazy rows changes their SwiftUI identity.
    // Keep it fixed while an existing reply grows.
    private final class MeasuredTail {
        struct Key: Equatable {
            let generation: UInt64
            let count: Int
            let first: String?
            let last: String?
        }

        private var key: Key?
        private var start = 0

        func split(_ rows: [ChatDisplayItem], generation: UInt64)
            -> (lazy: ArraySlice<ChatDisplayItem>, measured: ArraySlice<ChatDisplayItem>) {
            let next = Key(generation: generation, count: rows.count, first: rows.first?.id, last: rows.last?.id)
            if next != key {
                start = TranscriptSlice.measuredTailStart(rows)
                key = next
            }
            return TranscriptSlice.split(rows, measuredFrom: start)
        }
    }

    @State private var measuredTail = MeasuredTail()
    @State private var rowMounts = TranscriptRowMounts()
    /// Whether rows are reporting where they are. Set from the scroll
    /// callback as the top of the loaded conversation comes near, so the
    /// geometry readers exist for the stretch that can need an anchor and
    /// nowhere else.
    @State private var measuringRows = false
    /// How many newest rows sit below the built slice. Zero glues the
    /// ForEach to the end. Raised when the reader asks for older built
    /// rows, reset when they jump back. The stack is lazy, but every
    /// transaction still measures what it holds, so the slice stays a
    /// fixed width rather than growing.
    @State private var olderOffset = 0
    /// First row of the built slice, when it is not glued to the end.
    /// `olderOffset` is counted from the newest row, so a turn arriving
    /// below or a page landing above would otherwise replace what is on
    /// screen. This id is what keeps those rows still.
    @State private var sliceAnchor: [String] = []
    @State private var paneDropTargeted = false
    @State private var transcriptDropTargeted = false
    @State private var dropPresentation: UInt64 = 0
    @State private var composerDropTargeted = false
    /// Observed, so pinning from the sidebar or Home redraws the chrome
    /// without leaving the conversation.
    @State private var pins = PinnedWorkStore.shared
    @State private var showingHandoff = false
    /// The pull request for the folder's branch, from `pulls.branch`.
    @State private var branchPull: BranchPull?
    @State private var branchPullOwner: String?
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var paneContent: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar(
                scope: workspaceName.map { ScopeChip(label: $0, symbol: "folder.fill") },
                accessory: {
                    if let git, git.isRepo {
                        BranchChip(workspaceID: workspaceID, git: git) {
                            await onBranchChanged?()
                        }
                        .fixedSize()
                    }
                }
            ) {
                // New chat stays a button: it is the one thing people reach
                // for here. The rest is one menu, so the bar has room for the
                // project's own tabs.
                ToolbarMenuButton(help: L10n.text("apple.chatview.more_for_this_conversation.314ed3c2")) {
                    Button(showingOverview ? L10n.text("apple.chatview.back_to_the_conversation.481c16c4") : L10n.text("apple.chatview.all_conversations.ecf200f4"), .layout) {
                        showingOverview.toggle()
                    }
                    if !showingOverview, model.selected != nil, let reference = model.currentReference {
                        let pinned = pins.isPinned(reference)
                        let full = pins.pins(in: reference.scope).count >= PinnedWorkStore.capacity
                        Button(pinned ? L10n.text("apple.chatview.unpin_from_home.df00f5de") : L10n.text("apple.chatview.pin_to_home.db029e6f"), pinned ? .pinned : .pin) {
                            Task {
                                if pinned {
                                    await PinnedWorkActions.unpin(reference)
                                } else {
                                    await PinnedWorkActions.pin(
                                        reference,
                                        label: model.selected?.title ?? L10n.text("apple.chatview.chat.460b3a7d"),
                                        folderName: workspaceName ?? L10n.text("apple.chatview.project.98595978")
                                    )
                                }
                            }
                        }
                        .disabled(!pinned && full)
                        if !pinned && full {
                            Text(L10n.text("apple.chatview.home_holds_eight_pins_unpin_one_to_make_ro.7d0eb1cf"))
                        }
                    }
                    if !showingOverview, model.currentReference != nil, model.savedCopy == nil {
                        Button(L10n.text("apple.chatview.continue_on_another_device.b5836f9a"), .device) {
                            showingHandoff = true
                        }
                    }
                }
                // Narrow windows retain both actions in the conversation menu.
                if showsConversationToolbarActions, !showingOverview, model.selected != nil, let reference = model.currentReference {
                    let pinned = pins.isPinned(reference)
                    let full = pins.pins(in: reference.scope).count >= PinnedWorkStore.capacity
                    ToolbarIconButton(
                        systemImage: (pinned ? ActionIcon.pinned : ActionIcon.pin).symbol,
                        help: pinned ? L10n.text("apple.chatview.unpin_from_home.df00f5de")
                            : full ? L10n.text("apple.chatview.home_holds_eight_pins_unpin_one_to_make_ro.7d0eb1cf")
                            : L10n.text("apple.chatview.pin_to_home.db029e6f"),
                        isAccent: pinned,
                        isEnabled: pinned || !full
                    ) {
                        Task {
                            if pinned {
                                await PinnedWorkActions.unpin(reference)
                            } else {
                                await PinnedWorkActions.pin(
                                    reference,
                                    label: model.selected?.title ?? L10n.text("apple.chatview.chat.460b3a7d"),
                                    folderName: workspaceName ?? L10n.text("apple.chatview.project.98595978")
                                )
                            }
                        }
                    }
                }
                if showsConversationToolbarActions, !showingOverview, model.currentReference != nil, model.savedCopy == nil {
                    ToolbarIconButton(
                        systemImage: ActionIcon.device.symbol,
                        help: L10n.text("apple.chatview.continue_on_another_device.b5836f9a")
                    ) {
                        showingHandoff = true
                    }
                }
                ToolbarIconButton(
                    systemImage: "plus",
                    help: L10n.text("apple.chatview.new_chat.db18382a"),
                    isBusy: model.isCreating,
                    isEnabled: !model.isCreating
                ) {
                    openNewChat()
                }
            }
            #endif
            // Keep the transcript mounted while browsing the library so its
            // scroll view, rendered rows, and attachment views retain identity.
            ZStack {
            VStack(spacing: 0) {
            if let chat = model.selected {
                if isActive, model.savedCopy == nil, !model.isSharedSource {
                    WorkHandoffOffer(chat: model) { showingHandoff = true }
                }
                transcript(chat)
                if let notice = model.sharingRecoveryNotice {
                    TeamNotice(message: notice).padding(.horizontal, Theme.Space.m)
                }
                if model.isSharedSource {
                    ChatSharingNotice(model: model)
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: .infinity)
                }
                // A saved copy explains itself above the composer: what the
                // rows are, when they were kept, and the way back to live.
                if let copy = model.savedCopy {
                    ChatSavedCopyBanner(info: copy, checking: model.checkingSavedCopy) {
                        Task { await model.checkSavedCopyForUpdates() }
                    }
                    .frame(maxWidth: ReadingRoom.laneWidth)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.s)
                    .frame(maxWidth: .infinity)
                }
                if !model.isSharedSource, let note = chat.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    ChatSteerNoteBanner(
                        note: note,
                        waitingCount: model.pendingQueue.count,
                        turnRunning: model.busy,
                        onRemove: { model.clearSteer() },
                        onSendNow: { Task { await model.deliverParkedSteerNow() } }
                    )
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.bottom, Theme.Space.s)
                        .frame(maxWidth: .infinity)
                }
                // Pending writing stays available offline for copying or cancellation.
                // Sending and receipt checks require a live, verified owner.
                if !model.pendingQueue.isEmpty {
                    let queueOwner = model.currentReference
                    let queueCanSteer = model.busy && model.selected?.nativeSteer == true
                    let queueCanSteerAttachments = model.selected?.nativeSteerAttachments == true
                    ChatQueueStrip(
                        items: model.pendingQueue,
                        owner: queueOwner,
                        paused: model.queuePaused,
                        offline: model.savedCopy != nil || model.isSharedSource,
                        privateOnly: model.isSharedSource,
                        canSteer: queueCanSteer,
                        canSteerAttachments: queueCanSteerAttachments,
                        onChange: { item, text in model.updateQueued(item, text: text, owner: queueOwner) },
                        onRemove: { model.removeQueued($0, owner: queueOwner) },
                        onSendNow: { item in
                            showNewest()
                            follow.jump()
                            followPulse += 1
                            let steerOnly = queueCanSteer && ChatCommandRules.canSteer(item.text,
                                attachments: !item.attachments.isEmpty, acceptsAttachments: queueCanSteerAttachments)
                            Task { await model.sendNow(item, owner: queueOwner, steerOnly: steerOnly) }
                        },
                        onMove: { model.moveQueued(from: $0, to: $1, owner: queueOwner) }
                    )
                    .frame(maxWidth: ReadingRoom.laneWidth)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.s)
                    .frame(maxWidth: .infinity)
                }
                if let backend = model.backend(for: chat.backend), !model.isSharedSource, model.savedCopy == nil, model.signInGateRowID == nil {
                    ChatAgentSetupCard(model: model, backend: backend, running: model.busy,
                                       recoveryFailureID: model.signInFailureID)
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.bottom, Theme.Space.s)
                        .frame(maxWidth: .infinity)
                }
                if model.savedCopy == nil {
                    changesRow
                }
                ChatActivityStrip(model: model)
                    .frame(maxWidth: ReadingRoom.laneWidth)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.s)
                    .frame(maxWidth: .infinity)
                ChatComposer(
                    model: model,
                    chat: chat,
                    draft: $model.draft,
                    selection: $draftSelection,
                    attachments: model.attachments,
                    previews: model.attachmentPreviews,
                    running: model.busy,
                    sendsAsNote: model.sendsAsNote,
                    placeholder: model.isSharedSource ? L10n.text("common.teams.private_draft_placeholder") : model.sendsAsNote
                        ? (model.selected?.nativeSteer == true ? L10n.text("common.chat.steer_placeholder") : L10n.text("apple.chatview.add_a_note_for_the_next_step.4778177a"))
                        : (model.busy
                            ? L10n.text("apple.chatview.send_after_this_turn.012fc8c3")
                            : L10n.text("apple.chatview.ask_about_0.35c322e7", "\(workspaceName ?? L10n.text("apple.chatview.this_folder.9d6325c8"))")),
                    onSend: { submit(from: chat) },
                    onSendNow: { submit(from: chat, sendNow: true) },
                    onStop: { Task { await model.stop() } },
                    onAttach: { item, owner in await model.attach(item, to: owner) },
                    onRemove: { model.removeAttachment($0) },
                    acceptsDrops: showsDropTargets,
                    onDropProviders: { providers in
                        receive(providers)
                    },
                    onDropTargeted: { composerDropTargeted = $0 }
                )
                .equatable()
            } else if model.isReady(for: workspaceID), model.chats.isEmpty {
                empty
            } else {
                // Either nothing has been asked yet, or this folder's
                // conversations are known and one is about to be picked.
                // "Start a chat" belongs to neither: it is a promise about a
                // folder nobody has looked in, and it was being made every
                // time this pane was rebuilt.
                ChatPaneOpening()
            }
            }
            .transformEnvironment(\.personaMotionAllowed) { $0 = $0 && !showingOverview && isActive }
            .opacity(showingOverview ? 0 : 1)
            .allowsHitTesting(!showingOverview)
            .accessibilityHidden(showingOverview)
            if showingOverview {
                ChatConversationOverview(model: model, workspaceID: workspaceID, workspaceName: workspaceName) { conversation in
                    if model.selected?.id == conversation.id {
                        showingOverview = false
                    } else {
                        Task {
                            await model.select(conversation)
                            showingOverview = false
                        }
                    }
                } onNew: {
                    openNewChat()
                }
            }
            }
        }
    }

    // Opaque boundaries keep this pane's large content tree and modifier
    // chain independently type-checkable on the shipping Xcode toolchains.
    private var presentedChat: some View {
        paneContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .desktopPaneBackground()
        .chatDropSurface(enabled: showsDropTargets, isTargeted: $paneDropTargeted, receive: receive)
        .overlay {
            if dropExperienceVisible {
                ChatDropExperience()
            }
        }
        .overlay(alignment: .topTrailing) {
            TransientToast(message: $dropNotice, severity: .warning)
                .padding(.top, Theme.Space.m)
                .padding(.trailing, Theme.Space.m)
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: ChatDragSession.ended)) { _ in
            paneDropTargeted = false; transcriptDropTargeted = false; composerDropTargeted = false
        }
        .background {
            ChatNavigationKeys(isActive: isActive && !showingOverview) { step in
                model.stepConversation(step)
            }
            .frame(width: 0, height: 0)
        }
        #endif
        .sheet(isPresented: $showingHandoff) { WorkHandoffSheet(chat: model) }
        .chatImageViewer(model: model)
        .chatActivityPresentation(model: model, active: isActive && !showingOverview)
    }

    private var observedChat: some View {
        presentedChat
        // Asked again when the branch moves and when a turn ends, since an
        // agent may have just opened the pull request.
        .task(id: "\(workspaceID)|\(git?.branch ?? "")|\(model.busy)|\(isActive)") {
            // Keep the last answer for this folder and branch while asking again.
            let owner = "\(workspaceID)|\(git?.branch ?? "")"
            if branchPullOwner != owner {
                branchPull = nil
                branchPullOwner = owner
            }
            guard isActive, git?.isRepo == true, !model.busy else { return }
            guard let answer = try? await Bridge.branchPull(workspaceID: workspaceID, branch: git?.branch, refresh: true),
                  !Task.isCancelled, branchPullOwner == owner else { return }
            if answer.pull != branchPull { branchPull = answer.pull }
        }
        .onChange(of: isActive) { _, active in
            dropPresentation &+= 1
            if !active {
                showingHandoff = false
                settledPresentation = nil
                model.saveDraftNow()
                // Tear down scroll work before the LazyVStack is discarded.
                follow.freeze()
            } else {
                follow.active = true
            }
        }
        .onChange(of: showingOverview) { _, _ in dropPresentation &+= 1 }
        .onChange(of: model.readingIdentity) { previous, current in
            // A sheet belongs to the conversation that opened it.
            showingHandoff = false
            if previous.generation != current.generation { settleMood = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropExperienceVisible)
        #if os(macOS)
        .onExitCommand {
            if !showingOverview, model.busy { Task { await model.stop() } }
        }
        #endif
        #if !os(macOS)
        .navigationTitle(model.selected?.title ?? L10n.text("apple.chatview.chat.460b3a7d"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("apple.chatview.new_chat.db18382a"), .create, action: openNewChat)
            }
        }
        #endif
        .task(id: "\(workspaceID)-\(isActive)-\(String(describing: WorkSessionContext.shared.scope))-\(WorkSessionContext.shared.generation)") {
            Logger(subsystem: "ai.tokenstat.tokenstat", category: "chatload")
                .error("view task ws=\(workspaceID) active=\(isActive)")
            guard isActive, loadsWorkspace else { return }
            guard !model.consumePreparedInitialPresentation(workspaceID: workspaceID) else { return }
            await model.load(workspaceID: workspaceID)
        }
        // What is on screen, for the notifier. This pane stays mounted behind
        // other destinations, so `isActive` is the part `model.selected`
        // cannot answer on its own.
        #if os(macOS)
        .onChange(of: "\(model.selected?.id ?? "")-\(isActive)", initial: true) { _, _ in
            UserPresence.shared.chatSurface(showing: isActive ? model.selected?.id : nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task {
                guard isActive else { return }
                if loadsWorkspace { await model.load(workspaceID: workspaceID) }
                else if let selected = model.selected { await model.select(selected) }
                await model.resumeWaitingConnection()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatAttachmentCachePurged)) { _ in
            model.clearCachedAttachmentMemory()
        }
        // ⌥⌘↑ and ⌥⌘↓ from the View menu. Every chat pane that was ever
        // opened stays mounted, so only the one in front answers.
        .onReceive(NotificationCenter.default.publisher(for: .chatStepRequested)) { note in
            guard isActive, !showingOverview, let step = note.object as? Int else { return }
            _ = model.stepConversation(step)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatStepGroupsToggleRequested)) { _ in
            guard isActive, !showingOverview else { return }
            model.setAllGroups(open: !model.anyGroupOpen)
        }
        .onDisappear {
            UserPresence.shared.chatSurface(showing: nil)
        }
        #endif
        // Unsent words are written a third of a second after the last
        // keystroke. These two are the moments that can arrive sooner.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveDraftNow() }
            else {
                Task {
                    guard isActive else { return }
                    if loadsWorkspace { await model.load(workspaceID: workspaceID) }
                    else if let selected = model.selected { await model.select(selected) }
                    await model.resumeWaitingConnection()
                }
            }
        }
        .onDisappear { dropPresentation &+= 1; model.saveDraftNow() }
    }

    var body: some View {
        #if DEBUG && os(macOS)
        let _ = DebugUIHooks.printsChanges ? Self._printChanges() : ()
        #endif
        observedChat
        // And the same fact to the host, which is the one deciding whether a
        // phone hears about this turn.
        .watching(conversationID: model.selected?.id, peer: model.peer,
                  isActive: isActive && model.savedCopy == nil)
        .task(id: ChatPollWatchIdentity(owner: model.pollingIdentity,
                                       active: isActive && scenePhase == .active)) {
            guard isActive, scenePhase == .active else { return }
            await model.watchPolls()
        }
        .task(id: ChatPollWatchIdentity(owner: model.pollingIdentity,
                                       active: isActive && scenePhase == .active)) {
            guard isActive, scenePhase == .active else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await model.refillBackendsIfIncomplete()
        }
        #if DEBUG && os(macOS)
        // `key type:<text>` appends to the composer, one keystroke's worth of
        // draft change each, so typing during a stream can be measured.
        // `key clear-draft` empties it again.
        .onReceive(NotificationCenter.default.publisher(for: DebugUIHooks.keyRequested)) { note in
            guard isActive, let command = note.object as? String else { return }
            if command == "clear-draft" { model.draft = ""; return }
            guard command.hasPrefix("type:") else { return }
            model.draft += String(command.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\n")
        }
        #endif
        .modifier(ChatFileTransferControls(model: model))
        .modifier(ChatCacheWarningAlert(model: model, isActive: isActive))
        .alert(L10n.text("apple.chatview.chat_unavailable.a45aae80"), isPresented: Binding(
            get: { isActive && model.error != nil },
            set: { if !$0 && isActive { model.error = nil } }
        )) {
            Button(L10n.text("apple.chatview.ok.565339bc"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder
    private func transcript(_ chat: ChatConversation) -> some View {
        // Root keeps this pane mounted behind other destinations. Building the
        // LazyVStack while nobody can see it still measures markdown on every
        // parent layout pass, which is the multi-second main-thread freeze when
        // flipping through the sidebar. Model state stays; settle re-pins on
        // return. The library overview path above still keeps rows mounted
        // while browsing conversations inside Chat.
        if !isActive {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        // Once per pass, not once per reader of it. `visibleItems` copies the
        // window out of the conversation every time it is asked, and the
        // `ForEach` and the spinner both ask.
        let rows = visibleItems
        let spinning = TranscriptFollow.spinningRow(rows)
        let split = measuredTail.split(rows, generation: model.selectionGeneration)
        let liveRowID = model.busy && sliceOffset == 0 && !model.isShowingCachedTranscript ? rows.last?.id : nil
        let presentation = ChatPresentationIdentity(reading: model.readingIdentity, active: isActive)
        #if os(macOS)
        let verticalPadding = Theme.Space.m
        #else
        let verticalPadding = Theme.Space.xl
        #endif
        ScrollViewReader { proxy in
            let scroll = ScrollView {
                // Keep the bottom target measured even when a tall lazy row
                // is offscreen. Following must reach a real frame, not walk
                // toward an estimate until its correction budget runs out.
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        #if !os(macOS)
                        if !model.chats.isEmpty {
                            conversationMenu
                        }
                        #endif
                        if model.transcriptItems.isEmpty, !chat.running, !model.openingConversation {
                            emptyConversation
                        }
                        if hiddenAboveCount > 0 {
                            Button(L10n.text("apple.chatview.show_0_earlier_messages.2e5e4ab9", "\(hiddenAboveCount)"), .history) {
                                revealEarlier()
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityLabel(L10n.text("apple.chatview.show_earlier_messages.b6badd18"))
                        } else {
                            TranscriptEarlierHeader(model: model) {
                                follow.stopFollowing()
                                window.requestArchivePage()
                            }
                        }
                        ForEach(split.lazy) { item in
                            transcriptRow(item, chat: chat, spinning: spinning, isLive: item.id == liveRowID)
                                .allowsHitTesting(!follow.scrolling)
                                .transcriptRowMount(in: rowMounts, id: item.id, window: window)
                        }
                    }
                    // See `TranscriptSlice.measuredTail`.
                    ForEach(split.measured) { item in
                        transcriptRow(item, chat: chat, spinning: spinning, isLive: item.id == liveRowID)
                            .allowsHitTesting(!follow.scrolling)
                            .transcriptRowMount(in: rowMounts, id: item.id, window: window)
                    }
                    if sliceOffset == 0 {
                        if !model.isShowingCachedTranscript, let chat = model.selected, chat.routing?.limit != nil {
                            ChatRoutingNotice(model: model, chat: chat)
                                .id(chat.id)
                        }
                        if !model.isShowingCachedTranscript, let mood = liveMood {
                            ChatWorkingIndicator(
                                seed: model.faceSeed,
                                mood: mood,
                                step: TranscriptFollow.liveStep(model.transcriptItems),
                                startedAt: model.selected.flatMap { model.turnStartedAt(for: $0.id) },
                                still: follow.showJump
                            )
                        }
                        TranscriptBottomSentinel(trailingPadding: verticalPadding)
                    }
                }
                .allowsHitTesting(!model.isShowingCachedTranscript)
                .environment(\.streamingWordsPaused, follow.showJump || sliceOffset > 0)
                .onChange(of: follow.showJump || sliceOffset > 0, initial: true) { _, away in
                    LiveMarkdownReader.setAway(away)
                }
                .onDisappear { LiveMarkdownReader.setAway(false) }
                .frame(maxWidth: ReadingRoom.laneWidth, alignment: .leading)
                .padding(.top, verticalPadding)
                .padding(.bottom, sliceOffset == 0 ? 0 : verticalPadding)
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .top)
                #if os(macOS)
                .background { TranscriptScrollBounds(transcript: window).allowsHitTesting(false) }
                #endif
                .chatScrollContent()
            }
            let transcriptScroll = scroll
            .transcriptOpensAtEnd()
            .preserveStreamingScrollback(model.busy && !follow.pinned && !follow.settling, window: window)
            .chatDropSurface(enabled: showsDropTargets, isTargeted: $transcriptDropTargeted, receive: receive)
            .overlay {
                if settledSelection != Self.selectionKey(presentation) {
                    OpeningSkeleton().transition(.identity)
                }
            }
            .chatScrollMetrics { metrics in
                guard isActive, presentation.reading == model.readingIdentity else { return }
                #if DEBUG
                TranscriptProbe.shared.noteMetrics()
                TranscriptProbe.shared.pinned = follow.pinned
                TranscriptProbe.shared.scrolling = follow.scrolling
                TranscriptProbe.shared.built = rows.count
                #endif
                // The slice flag first: note() treats a hidden newest as
                // far from the end. Then the pin, then the window, which
                // has to see that decision on the same frame.
                follow.sliceHidesNewest = sliceOffset > 0
                follow.note(metrics)
                window.followingEnd = (follow.pinned || follow.settling) && sliceOffset == 0
                window.note(metrics)
            }
            .transcriptFollowBar {
                if follow.showJump || model.busy {
                    TranscriptFollowPill(
                        showJump: follow.showJump,
                        busy: model.busy,
                        paused: follow.paused,
                        resume: {
                            Task { await returnToLatest(proxy, for: presentation.reading) }
                        },
                        pause: { follow.pause() }
                    )
                }
            }
            .transcriptEarlierPages(model, window: window, proxy: proxy, isActive: isActive,
                                    hiddenEarlierRows: hiddenAboveCount, hiddenLaterRows: sliceOffset,
                                    revealEarlier: revealEarlier, revealLater: revealLater,
                                    holdSliceStart: holdSliceStart)
            transcriptScroll
            .onChange(of: structureToken) { _, _ in
                // Opening owns placement while the cached rows and the live
                // page trade places. Later structural changes can follow normally.
                guard settledPresentation == presentation,
                      presentation.reading == model.readingIdentity,
                      !follow.settling, !follow.atEnd else { return }
                pinToLatest(proxy, animated: !model.busy)
            }
            .onChange(of: followPulse) { _, _ in
                Task { await returnToLatest(proxy, for: presentation.reading) }
            }
            .onChange(of: model.busy) { was, now in
                guard presentation.reading == model.readingIdentity else { return }
                if settledPresentation == presentation {
                    settleAfterTurn(was: was, now: now)
                }
                if was, !now {
                    Task { await model.drainQueue() }
                }
            }
            .onChange(of: model.approvals.map(\.id)) { _, ids in
                follow.suppressed = !ids.isEmpty
                if follow.pinned, let id = ids.first { scrollTarget = "approval-\(id)" }
            }
            // A scroll that has come to rest is a reader who has stopped
            // somewhere. Wait a beat for the rows to say where they are:
            // they report on the update this change itself causes.
            .onChange(of: follow.scrolling) { _, moving in
                guard !moving, isActive else { return }
                let reference = model.currentReference
                let generation = model.selectionGeneration
                Task {
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled, !follow.scrolling, !follow.settling,
                          reference == model.currentReference,
                          generation == model.selectionGeneration else { return }
                    TranscriptReading.record(follow: follow, window: window,
                                             for: reference)
                }
            }
            .onChange(of: isActive, initial: true) { _, active in
                if active {
                    follow.active = true
                } else {
                    // Drop metrics and pending repins before the stack tears
                    // down; otherwise a last geometry sample can still mark
                    // scrolling and invalidate work on the way out.
                    follow.freeze()
                }
                // The presentation-keyed task owns settling on reactivation.
            }
            // A request that arrives while a reply is still streaming would
            // otherwise be pushed off the top of the page before anyone saw
            // it. Bring the card to them.
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
                prepareTranscript(presentation, rowCount: rows.count)
            }
            .task(id: presentation) {
                guard !Task.isCancelled, isActive, presentation.reading == model.readingIdentity else { return }
                let ticket = UUID()
                settleTaskID = ticket
                settledPresentation = nil
                installRepin(proxy, for: presentation)
                follow.settle(true)
                window.followingEnd = true
                showNewest()
                defer {
                    if settleTaskID == ticket, presentation.reading == model.readingIdentity {
                        #if os(macOS)
                        DiagnosticsLog.note("chat viewport settle end=\(follow.exactlyAtEnd) rows=\(model.transcriptItems.count) cancelled=\(Task.isCancelled)")
                        #endif
                        follow.settle(false)
                        if !Task.isCancelled {
                            settledPresentation = presentation
                            settledSelection = Self.selectionKey(presentation)
                        }
                    }
                }
                // The cached tail can be measured while the live page loads.
                // Reveal after the live page has stayed at its actual bottom.
                while model.openingConversation {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, settleTaskID == ticket,
                          presentation.reading == model.readingIdentity else { return }
                }
                guard !Task.isCancelled, presentation.reading == model.readingIdentity else { return }
                if await restoreReadingPlace(proxy) != .unavailable { return }
                guard !Task.isCancelled, settleTaskID == ticket,
                      presentation.reading == model.readingIdentity else { return }
                var previousBottomLayout: UInt64?
                var correctionPins = 0
                for _ in 0..<Self.settleFrames {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, settleTaskID == ticket,
                          presentation.reading == model.readingIdentity,
                          !follow.abandoned, model.approvals.isEmpty else { return }
                    if follow.exactlyAtEnd {
                        let revision = follow.layoutRevision
                        if previousBottomLayout == revision { return }
                        previousBottomLayout = revision
                    } else {
                        previousBottomLayout = nil
                        if correctionPins < 8, pinToLatest(proxy, animated: false) {
                            correctionPins += 1
                        }
                    }
                }
            }
            .task(id: settleMood) {
                guard settleMood == .ok else { return }
                do { try await Task.sleep(for: .milliseconds(480)) } catch { return }
                settleMood = nil
            }
            .task(id: presentation) {
                await watchMountedRows(proxy, for: presentation)
            }
        }
        #if os(macOS)
        // Archive row IDs repeat across chats. Reusing the native scroll
        // view also reused its lazy layout estimates and scroll targets,
        // sometimes leaving a loaded conversation entirely offscreen after
        // arrow navigation. Keep the composer/pane, but give each selected
        // window its own scroll view. Paging and streaming retain this one.
        .id(ChatReadingIdentity(reference: presentation.reading.reference,
                                generation: presentation.reading.generation))
        #endif
        }
    }

    private static func selectionKey(_ presentation: ChatPresentationIdentity) -> ChatReadingIdentity {
        ChatReadingIdentity(reference: presentation.reading.reference, generation: presentation.reading.generation)
    }

    private func prepareTranscript(_ presentation: ChatPresentationIdentity, rowCount: Int) {
        guard presentation.reading == model.readingIdentity else { return }
        #if os(macOS)
        // A new scroll view needs fresh paging anchors and pin timing.
        window.release()
        window.clearRowFrames()
        window.followingEnd = true
        window.releaseFollow = { [follow] in follow.releaseForReaderWheel() }
        lastSilentPinAt = .distantPast
        DiagnosticsLog.note("chat viewport remount previousEnd=\(follow.atEnd) rows=\(rowCount)")
        follow.resetViewport()
        #if DEBUG
        TranscriptProbe.shared.noteViewportReset()
        #endif
        #endif
        follow.suppressed = !model.approvals.isEmpty
        if follow.pinned, let id = model.approvals.first?.id { scrollTarget = "approval-\(id)" }
        window.nearTopChanged = { measuringRows = $0 }
    }

    private func transcriptRow(_ item: ChatDisplayItem, chat: ChatConversation, spinning: String?, isLive: Bool) -> some View {
        let owner = model.currentReference
        let generation = model.selectionGeneration
        return Group {
            if item.id == model.signInGateRowID, model.savedCopy == nil,
               let backend = model.backend(for: chat.backend) {
                ChatAgentSetupCard(model: model, backend: backend, running: model.busy,
                                   recoveryFailureID: model.signInFailureID)
            } else {
                ChatEventRow(
                    item: item,
                    defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                    agentLabel: { backend in
                        model.backend(for: backend)?.label ?? backend.capitalized
                    },
                    attachmentData: attachmentData(for: item),
                    isPending: pendingApproval(item),
                    resolve: { approval, choice in
                        let owner = model.currentReference
                        Task { await model.resolve(approval, choice: choice, owner: owner) }
                    },
                    attachmentFile: model.responseAttachmentFiles[attachmentID(for: item)],
                    imageResources: model.imageResources(for: item.imageAttachments),
                    attachmentIsLoading: model.loadingResponseAttachments.contains(attachmentID(for: item)),
                    attachmentError: model.responseAttachmentErrors[attachmentID(for: item)],
                    downloadAttachment: { attachment in
                        Task { await model.downloadResponseAttachment(attachment) }
                    },
                    canOpenAttachment: {
                        guard let owner else { return false }
                        return model.currentReference == owner && model.selectionGeneration == generation
                            && WorkCacheAccess.canRead(owner)
                    },
                    faceSeed: model.faceSeed,
                    isLive: isLive,
                    animatesRunning: !model.isShowingCachedTranscript && item.id == spinning,
                    expandsOutput: detail.level == .detailed,
                    compactTools: detail.level == .minimal,
                    toggleGroup: { model.toggleGroup($0) },
                    answerQuestion: { question, text in
                        Task { await model.answerQuestion(question, answer: text) }
                    },
                    answeringQuestion: model.answeringQuestions.contains(item.questionID ?? ""),
                    canAnswerQuestions: !model.isSharedSource && model.savedCopy == nil && !model.isShowingCachedTranscript,
                    reviewChanges: model.savedCopy == nil ? onReviewChanges : nil,
                    reviewTurnChanges: onReviewTurnChanges
                )
                .equatable()
            }
        }
        .frame(
            maxWidth: item.prefersWideReadingRoom
                ? .infinity
                : ReadingRoom.proseWidth,
            alignment: .leading
        )
        .frame(maxWidth: .infinity, alignment: item.readingRoomAlignment)
        // No geometry readers mid-fling: each one reports per
        // frame, and a fast scroll turns those reports into a
        // transaction per frame that placement never drains.
        // Readers return 0.35s after the last moved frame, via
        // `scrolling`, before any paging decision needs them.
        // Near the top of a long conversation, where a page
        // may land and the reader's place has to be held; and
        // wherever the reader has stopped above the latest
        // turn, because that place is worth keeping. Never
        // mid-scroll: that is a report per row per frame.
        .transcriptRowFrame(
            item.id,
            watched: !follow.scrolling && (measuringRows || !follow.atEnd)
        )
    }

    /// Bound the number of layout samples after the live page arrives.
    private static let settleFrames = 24

    /// Rows the transcript builds this pass. A fixed-width slice, never a
    /// growing suffix: appending below the viewport shifts nothing, earlier
    /// pages arrive through the paging path, older built rows by sliding.
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
        if olderOffset > 0, !sliceAnchor.isEmpty {
            return TranscriptSlice.holding(sliceAnchor, in: model.transcriptItems, current: olderOffset)
        }
        return TranscriptSlice.clampOffset(olderOffset, count: model.transcriptItems.count)
    }

    private func showNewest() {
        applySlice(0)
    }

    /// Keep the slice on the row it starts on while a page lands (`true`),
    /// then let a slice the page did not move glue to the end again.
    private func holdSliceStart(_ holding: Bool) {
        if holding {
            let start = visibleItems.prefix(8).map(\.id)
            guard !start.isEmpty else { return }
            sliceAnchor = start
            olderOffset = max(olderOffset, 1)
        } else if sliceOffset == 0, olderOffset > 0 {
            olderOffset = 0
            sliceAnchor = []
        }
    }

    /// Slide the built slice towards the start, holding the reader's row
    /// where it is. Without the hold the rows brought in above pushed the
    /// conversation down by a whole slide, the reader landed at the top of
    /// them, and that was the top of the slice again: the next slide fired,
    /// and the one after, until the start of the chat.
    private func revealEarlier() {
        // The window's flag runs ahead of the view after a page lands. With
        // nothing actually above the slice, ask the archive instead of
        // sliding a slice that cannot move, which was a loop at the top of
        // the conversation with nothing loading.
        guard hiddenAboveCount > 0 else {
            window.hasHiddenEarlierRows = false
            window.ask()
            return
        }
        // Never drop a row the reader can see from the bottom of the slice.
        let room = window.slideRoom(in: visibleItems.map(\.id), later: false)
        guard room > 0 else { return }
        follow.stopFollowing()
        window.holdPlace("slide-earlier")
        applySlice(
            TranscriptSlice.revealingEarlier(
                count: model.transcriptItems.count, olderOffset: sliceOffset, limit: room
            )
        )
    }

    /// Slide back towards the newest rows as the reader reaches the end of
    /// the slice. The rows dropped from the top move what is on screen up by
    /// their height, so the place is held the same way.
    private func revealLater() {
        guard sliceOffset > 0 else {
            window.hasHiddenLaterRows = false
            return
        }
        // Nor from its top.
        let room = window.slideRoom(in: visibleItems.map(\.id), later: true)
        guard room > 0 else { return }
        window.holdPlace("slide-later")
        applySlice(
            TranscriptSlice.revealingLater(
                count: model.transcriptItems.count, olderOffset: sliceOffset, limit: room
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
            ).prefix(8).map(\.id)
            follow.sliceHidesNewest = true
        } else {
            sliceAnchor = []
            follow.sliceHidesNewest = false
        }
    }


    /// A reopened transcript owns its new viewport and places it at the end.
    /// Only a jump within the current transcript may use this scroll proxy.
    private func returnToLatest(_ proxy: ScrollViewProxy, for reading: ChatReadingIdentity) async {
        guard !Task.isCancelled, isActive, reading == model.readingIdentity,
              !model.openingConversation, !follow.settling else { return }
        window.release()
        if let reference = model.currentReference { ChatReadingStore.shared.requestLatest(for: reference) }
        if model.canDiscardPagedHistory {
            window.followingEnd = true
            await model.reopenAtLatest()
            return
        }
        showNewest()
        follow.jump()
        await chaseLatest(proxy)
    }

    /// Keep asking for the end until the view is actually there.
    ///
    /// One scroll is not enough from far away: a lazy stack answers on
    /// estimated heights and corrects them as it builds the rows in between.
    /// This stops as soon as the scroll callback reports the end steady, so
    /// a short hop costs two frames.
    private func chaseLatest(_ proxy: ScrollViewProxy) async {
        let reading = model.readingIdentity
        follow.chase(true)
        defer { if reading == model.readingIdentity { follow.chase(false) } }
        for _ in 0..<Self.chaseFrames {
            guard !Task.isCancelled, isActive, reading == model.readingIdentity, !follow.abandoned else { return }
            if !follow.atEnd { pinToLatest(proxy, animated: false) }
            try? await Task.sleep(for: .milliseconds(40))
            guard reading == model.readingIdentity else { return }
            if follow.steadyFrames >= 2 { return }
        }
    }

    /// How many frames one press of Jump to latest may spend arriving.
    private static let chaseFrames = 24

    /// Let the scroll callback put the viewport back on the end.
    ///
    /// Weak, because the state owns the closure and the closure would
    /// otherwise own the state. The proxy and the model are both fine to hold:
    /// neither is owned by what is holding this.
    private func installRepin(_ proxy: ScrollViewProxy, for presentation: ChatPresentationIdentity) {
        let state = follow
        let model = model
        state.repin = { [weak state] in
            guard let state, presentation.reading == model.readingIdentity,
                  state.active, state.pinned, !state.sliceHidesNewest, model.approvals.isEmpty else { return false }
            state.markDrivenInstant()
            proxy.scrollTo(TranscriptFollow.bottomID, anchor: .bottom)
            return true
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

    #if !os(macOS)
    private var conversationMenu: some View {
        Menu(model.selected?.title ?? L10n.text("apple.chatview.chat.460b3a7d")) {
            ForEach(model.chats) { conversation in
                Button(conversation.title) { Task { await model.select(conversation) } }
            }
        }
    }
    #endif

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

    /// Whether a scroll to the end is the actual latest turn.
    ///
    /// The ForEach is a bounded slice, so walking it is cheap. A slice that
    /// has dropped the newest rows is not the end, and pinning it would pin
    /// a sentinel under old messages.
    private var canScrollToEnd: Bool { sliceOffset == 0 }

    /// See `TranscriptRowMounts`. Pinning again does not rebuild the rows:
    /// the end sentinel sits outside the lazy stack. Scrolling to the top of
    /// the last row does, because the stack has to build that row to place
    /// it, and the end is pinned again after. Only a reader following the
    /// end is moved. Anyone else is scrolling themselves, which rebuilds the
    /// rows anyway. Bounded, so a chat that really has nothing to build
    /// cannot keep moving the view.
    private func watchMountedRows(_ proxy: ScrollViewProxy, for presentation: ChatPresentationIdentity) async {
        guard isActive else { return }
        var repairs = 0
        var emptySamples = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard presentation.reading == model.readingIdentity else { return }
            // The repair must not compete with opening placement.
            if settledPresentation != presentation || rowMounts.showsRows(viewportHeight: window.viewportHeight) || visibleItems.isEmpty
                || model.openingConversation || follow.settling || follow.scrolling || !follow.pinned || !canScrollToEnd {
                emptySamples = 0
                if rowMounts.showsRows(viewportHeight: window.viewportHeight) { repairs = 0 }
                continue
            }
            emptySamples += 1
            guard emptySamples >= 2, repairs < 3, let last = visibleItems.last?.id else { continue }
            repairs += 1
            emptySamples = 0
            follow.markDrivenInstant()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(last, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, presentation.reading == model.readingIdentity else { return }
            guard isActive, follow.pinned, !follow.settling, !follow.scrolling, canScrollToEnd else { continue }
            follow.markDrivenInstant()
            lastSilentPinAt = .distantPast
            pinToLatest(proxy, animated: false)
        }
    }

    @discardableResult
    private func pinToLatest(_ proxy: ScrollViewProxy, animated: Bool) -> Bool {
        // A pending request owns the view. Streaming text must not scroll it
        // back out from under somebody who is reading it to decide.
        // And a hidden pane owns no viewport: this view stays mounted behind
        // other destinations, and scrolling its zero-size proxy is what left
        // it painted off-origin until a resize.
        guard isActive, follow.pinned, model.approvals.isEmpty else { return false }
        guard canScrollToEnd else {
            follow.stopFollowing()
            return false
        }
        if !animated {
            let now = Date()
            guard now.timeIntervalSince(lastSilentPinAt) > 0.15 else { return false }
            lastSilentPinAt = now
        }
        scrollTo(TranscriptFollow.bottomID, proxy, animated: animated)
        return true
    }

    private func scrollTo(_ id: String, _ proxy: ScrollViewProxy, animated: Bool) {
        // Every scroll here is programmatic. Say so, or the frames of the
        // animation read as the reader leaving and unpin mid-flight.
        // Instant pins land on the same frame and only need a short window;
        // the long one is what locked out slow scrollback during streams.
        // Hidden panes do not scroll at all (see pinToLatest).
        guard isActive else { return }
        // The end always exists. Anything else may sit outside the built
        // slice: slide to it first, or the scroll lands nowhere.
        if id != TranscriptFollow.bottomID {
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
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            withAnimation(.easeOut(duration: TranscriptFollow.structureDuration)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    /// Only an explicit search/shared-reading request overrides opening at
    /// the latest turn. Passive reading history does not move a new selection.
    private func restoreReadingPlace(_ proxy: ScrollViewProxy) async -> TranscriptReading.Restoration {
        guard let reference = model.currentReference,
              let mark = ChatReadingStore.shared.takeRequest(for: reference) else { return .unavailable }
        return await TranscriptReading.restore(mark, reference: reference, model: model, follow: follow) { id, point in
            placeRow(id, proxy, at: point)
        }
    }

    /// Put one row where the reader had it, with the rest of the conversation
    /// below it and the earlier part one button above.
    private func placeRow(_ id: String, _ proxy: ScrollViewProxy, at point: UnitPoint) {
        guard isActive else { return }
        applySlice(TranscriptSlice.holding([id], in: model.transcriptItems, current: 0))
        follow.markDrivenInstant()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: point)
        }
    }

    /// The folder's uncommitted work and the branch's pull request, just
    /// above the composer. Nothing at all when there is neither.
    @ViewBuilder
    private var changesRow: some View {
        ChatGitStatusStrip(git: git, pull: branchPull,
                           review: onReviewChanges.map { callback in { callback(nil) } })
            .frame(maxWidth: ReadingRoom.laneWidth)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.xs)
            .frame(maxWidth: .infinity)
    }

    private func pendingApproval(_ item: ChatDisplayItem) -> Bool {
        if case let .approval(approval) = item.kind {
            return model.approvalIsPending(approval)
        }
        return false
    }

    private func submit(from chat: ChatConversation, sendNow: Bool = false, cacheConfirmed: Bool = false) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isSharedSource, !text.isEmpty || !model.attachments.isEmpty, !model.sending else { return }
        if model.consumeChatCommand() { return }
        switch model.holdForSignIn(text, backend: chat.backend) {
        case .notNeeded: break
        case .refused: return
        case .held:
            showNewest()
            follow.jump()
            followPulse += 1
            return
        }
        // Enqueue first: a full queue reports an error and returns nil, and
        // the words must survive that path rather than being wiped.
        if sendNow {
            guard let item = model.enqueue(text, atFront: true) else { return }
            model.clearDraft()
            // Sending is engaging: follow is the default, so a new turn resumes
            // it even if it was paused before. Pausing again is one tap. The
            // pulse scrolls now; the token pins take over as content arrives.
            showNewest()
            follow.jump()
            followPulse += 1
            let queueOwner = model.currentReference
            Task { await model.sendNow(item, owner: queueOwner, forceStop: true) }
            return
        }
        if model.busy {
            switch model.beginBusyNote(text) {
            case .queue:
                guard model.enqueue(text) != nil else { return }
                model.clearDraft()
                showNewest()
                follow.jump()
                followPulse += 1
                return
            case .steering(let token):
                showNewest()
                follow.jump()
                followPulse += 1
                Task {
                    await model.finishBusyNote(token)
                }
                return
            }
        }
        // A long pause emptied the prompt cache: this message would make the
        // agent read the whole conversation again. Ask first.
        if !cacheConfirmed,
           !ChatPromptCacheRule.isSuppressed(ChatPromptCacheRule.idleSuppressedKey),
           let idle = ChatPromptCacheRule.idle(chat, nowMs: ChatModel.nowMs),
           let cache = ChatPromptCacheRule.cache(chat) {
            askBeforeColdSend(chat, text: text, idleMs: idle, tokens: cache.tokens)
            return
        }
        // The composer empties, the stored copy does not: it is dropped when
        // the host has the words and put back when it refuses them.
        guard model.holdDraftForSending(text) else { return }
        showNewest()
        follow.jump()
        followPulse += 1
        Task { await model.sendFromComposer() }
    }

    private func askBeforeColdSend(_ chat: ChatConversation, text: String, idleMs: Int64, tokens: UInt64) {
        let peer = model.peer
        // Files are uploaded into this chat, so a message carrying them
        // cannot move to another one.
        let movable = model.attachments.isEmpty && model.savedCopy == nil
        Task { @MainActor () -> Void in
            let canStart = movable ? await RemoteHostFeature.chatContinue.isSupported(peer: peer) : false
            guard model.selected?.id == chat.id,
                  model.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            presentColdSendWarning(chat, text: text, idleMs: idleMs, tokens: tokens, canStart: canStart)
        }
    }

    private func presentColdSendWarning(_ chat: ChatConversation, text: String, idleMs: Int64,
                                        tokens: UInt64, canStart: Bool) {
        var startNew: (@MainActor () -> Void)?
        if canStart {
            startNew = { continueInNewChat(text, from: chat) }
        }
        let proceed: @MainActor () -> Void = {
            guard model.selected?.id == chat.id, let current = model.selected else { return }
            submit(from: current, cacheConfirmed: true)
        }
        model.cacheWarning = ChatCacheWarning(kind: .idle(idleMs: idleMs, startNew: startNew),
                                              tokens: tokens, proceed: proceed)
    }

    /// Move this message into a new chat that continues this one, and send it
    /// there. The words go back where they were if the new chat cannot be made.
    private func continueInNewChat(_ text: String, from chat: ChatConversation) {
        guard model.selected?.id == chat.id,
              model.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text,
              model.attachments.isEmpty, let reference = model.currentReference else { return }
        let words = model.draft
        model.saveDraftNow()
        let original = ChatDraftStore.shared.draft(for: reference)
        Task { @MainActor () -> Void in
            guard let created = await model.continueInNew(chat, expectedDraft: words) else { return }
            model.draft = words
            model.saveDraftNow()
            if !model.draftSaveFailed, let original { ChatDraftStore.shared.clear(original) }
            submit(from: created, cacheConfirmed: true)
        }
    }

    private var dropExperienceVisible: Bool {
        (paneDropTargeted || transcriptDropTargeted || composerDropTargeted) && showsDropTargets
    }

    /// Leaves out the folder list read, so it does not redraw the pane. `acceptsDrops` checks it on drop.
    private var showsDropTargets: Bool {
        isActive && !showingOverview && !model.sending
            && model.folderID == workspaceID
            && (model.currentReference.map(WorkCacheAccess.canRead)
                ?? (model.savedCopy == nil && model.selected == nil && model.chats.isEmpty))
    }

    private var acceptsDrops: Bool {
        showsDropTargets && model.isReady(for: workspaceID)
    }

    @discardableResult
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrops, !providers.isEmpty else { return false }
        let owner = model.currentReference
        let folder = model.folderID
        let peer = model.peer
        let scope = WorkSessionContext.shared.readingScope
        let generation = model.selectionGeneration
        let presentation = dropPresentation
        Task {
            let drops = await ChatInbox.drops(from: providers)
            defer {
                for case let .attachment(item) in drops {
                    if let file = item.file { try? FileManager.default.removeItem(at: file) }
                }
            }
            guard !Task.isCancelled, dropPresentation == presentation, acceptsDrops, !drops.isEmpty,
                  model.folderID == folder, model.peer == peer,
                  WorkSessionContext.shared.readingScope == scope else { return }
            var destination = owner
            if destination == nil {
                guard model.currentReference == nil, model.folderID == folder, model.peer == peer,
                      model.selectionGeneration == generation,
                      WorkSessionContext.shared.readingScope == scope else { return }
                guard let created = await model.create(), let folder else { return }
                guard !Task.isCancelled, dropPresentation == presentation, acceptsDrops, model.selected?.id == created.id,
                      model.folderID == folder, model.peer == peer,
                      WorkSessionContext.shared.readingScope == scope else { return }
                destination = model.draftReference(for: created.id, in: folder)
            }
            guard let destination else { return }
            await receive(drops, owner: destination)
        }
        return true
    }

    private func receive(_ drops: [ChatInboxDrop], owner: WorkReference) async {
        for drop in drops {
            guard !Task.isCancelled, WorkCacheAccess.canRead(owner) else { return }
            switch drop {
            case let .attachment(item):
                await model.attach(item, to: owner)
            case let .text(text):
                if model.currentReference == owner {
                    insertInDraft(text)
                } else {
                    model.appendImportedText(text, to: owner)
                }
            case .folder:
                showDropNotice(L10n.text("apple.chatview.attach_files_not_folders.9039f9a4"))
            }
        }
    }

    private func insertInDraft(_ text: String) {
        let current = model.draft as NSString
        let location = min(max(0, draftSelection.location), current.length)
        let length = min(max(0, draftSelection.length), current.length - location)
        model.draft = current.replacingCharacters(
            in: NSRange(location: location, length: length), with: text)
        draftSelection = NSRange(location: location + (text as NSString).length, length: 0)
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

    private func openNewChat() {
        if let onNewChat { onNewChat() }
        else { Task { if await model.create() != nil { showingOverview = false } } }
    }

    private var emptyConversation: some View {
        VStack(spacing: Theme.Space.m) {
            ChatScene(seed: model.defaultFaceSeed)
            Text(L10n.text("apple.chatview.ask_about_0.35c322e7", "\(workspaceName ?? L10n.text("apple.chatview.this_folder.9d6325c8"))"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.m)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            ChatScene(seed: model.defaultFaceSeed)
            Text(L10n.text("apple.chatview.start_a_chat.d80b1888"))
                .font(Theme.title2.weight(.semibold))
            Text(L10n.text("apple.chatview.ask_an_agent_to_explore_plan_or_work_in_th.ebcac953"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(L10n.text("apple.chatview.new_chat.db18382a"), .create) {
                openNewChat()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(model.isCreating)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.l)
    }
}

/// The pane between arriving and knowing.
///
/// It says nothing at first, because most opens are quicker than a spinner is
/// worth and a spinner that appears for one frame is itself the flicker. A
/// slow host still gets to admit it is waiting.
private struct ChatPaneOpening: View {
    @State private var waited = false

    var body: some View {
        VStack {
            if waited {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            waited = true
        }
    }
}

/// The transcript and composer share one desktop grid. Prose keeps a readable
/// measure in its centre while structured content can use the full lane.
private extension ChatDisplayItem {
    var prefersWideReadingRoom: Bool {
        switch kind {
        case .tool, .edit, .group, .question, .attachment, .approval, .handoff, .turnSeparator, .usage, .changes, .plan:
            true
        case .user, .assistant, .thinking, .failed:
            false
        }
    }

    var readingRoomAlignment: Alignment {
        switch kind {
        case .user:
            .trailing
        case .assistant, .thinking, .failed:
            .leading
        case .tool, .edit, .group, .question, .attachment, .approval, .handoff, .turnSeparator, .usage, .changes, .plan:
            .center
        }
    }
}

/// One themed promise for every chat drop target, from a wide Mac transcript
/// to an empty iPad conversation.
struct ChatDropExperience: View {

    var body: some View {
        ZStack {
            Theme.accentSoft.opacity(0.58)
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.82), lineWidth: 1.5)
                .padding(8)
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "paperclip")
                    .font(Theme.font(36, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 58, height: 58)
                Text(L10n.text("apple.chatview.drop_to_attach.34a7a637"))
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(L10n.text("apple.chatview.files_attach_text_and_links_join_your_mess.66780aaf"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.34), lineWidth: 1)
            }
            .shadow(color: Theme.shadow(0.18), radius: 18, y: 8)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
/// Hover state stays with the row, so moving between names does not rebuild
/// the conversation list. SwiftUI cancels the dwell when the row disappears.
private struct ConversationPreviewHover: ViewModifier {
    let warm: () async -> Void
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0 }
            .task(id: hovered) {
                guard hovered else { return }
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard !Task.isCancelled else { return }
                await warm()
            }
    }
}
#endif

/// Keep the transcript laid out behind the cover. Delay the wireframe so a
/// fast selection can appear directly at the latest message.
private struct OpeningSkeleton: View {
    @State private var showsSkeleton = false

    var body: some View {
        Theme.background
            .overlay {
                if showsSkeleton {
                    TranscriptSkeleton()
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                showsSkeleton = true
            }
    }
}

#if os(macOS)
/// Keep the native clip view within its document while the reader is at an
/// edge. A rubber-band frame can make the lazy history change its estimates
/// and trigger a follow correction while the scroll view is springing back.
#if DEBUG
/// A reader's wheel gesture, delivered to the transcript's own scroll view.
///
/// Built as real phased scroll events rather than an offset change, so the
/// transcript sees what it sees from a trackpad: `interacting`, then rest.
/// `ai.tokenstat.debug.key` with `wheel:<points per step>:<steps>`. Positive
/// points move towards the start of the conversation.
@MainActor
enum DebugTranscriptWheel {
    /// Every transcript reports in. Retained panes keep hidden ones alive,
    /// so the one a gesture goes to is the visible one, not the last laid out.
    private static let reporters = NSHashTable<TranscriptScrollBounds.Reporter>.weakObjects()
    fileprivate static var reporter: TranscriptScrollBounds.Reporter? {
        get {
            reporters.allObjects.first { view in
                view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor
                    && (view.enclosingScrollView?.visibleRect.height ?? 0) > 0
                    && (view.enclosingScrollView?.alphaValue ?? 0) > 0
            }
        }
        set { if let newValue { reporters.add(newValue) } }
    }

    /// A trackpad gesture as the window receives it: finger phases, then a
    /// momentum tail, delivered to the window so hit
    /// testing and the scroll view's own handling all run the way they do
    /// for a real swipe. `momentum` is how many decaying tail events follow.
    static func gesture(points: Int32, steps: Int, momentum: Int = 0) {
        guard let scrollView = reporter?.enclosingScrollView, let window = scrollView.window else { return }
        // An event made here has no window, so AppKit reports its screen
        // position as its position in the window it is sent to. Give it the
        // window point, or hit testing lands wherever the window is not.
        let local = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
        let height = NSScreen.screens.first?.frame.height ?? 0
        let location = CGPoint(x: local.x, y: height - local.y)
        _ = window
        Task { @MainActor in
            for step in 0..<max(1, steps) {
                send(points, phase: step == 0 ? 1 : 2, momentum: 0, at: location)
                try? await Task.sleep(for: .milliseconds(16))
            }
            send(0, phase: 4, momentum: 0, at: location)
            guard momentum > 0 else { return }
            var value = Double(points)
            for index in 0..<momentum {
                value *= 0.92
                let phase: Int64 = index == 0 ? 1 : (index == momentum - 1 ? 3 : 2)
                send(Int32(value.rounded()), phase: 0, momentum: phase, at: location)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private static func send(_ points: Int32, phase: Int64, momentum: Int64, at location: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: points, wheel2: 0, wheel3: 0) else { return }
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(points) << 16)
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        // A local monitor only sees events the app dequeues, and a Debug
        // hook runs in the background, so do what the monitor does first.
        if points != 0 { reporter?.noteWheel(towardEarlier: points > 0) }
        reporter?.window?.sendEvent(nsEvent)
    }
}
#endif

private struct TranscriptScrollBounds: NSViewRepresentable {
    let transcript: TranscriptWindow

    func makeNSView(context: Context) -> Reporter {
        let view = Reporter()
        view.transcript = transcript
        return view
    }

    func updateNSView(_ view: Reporter, context: Context) {
        view.transcript = transcript
        view.clampScrolling()
    }

    final class Reporter: NSView {
        weak var transcript: TranscriptWindow?
        private var wheelMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clampScrolling()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            guard window != nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let scroll = self.enclosingScrollView,
                       !self.isHiddenOrHasHiddenAncestor, event.window === self.window, event.scrollingDeltaY != 0,
                       scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) {
                        self.noteWheel(towardEarlier: event.scrollingDeltaY > 0)
                    }
                }
                return event
            }
        }

        func noteWheel(towardEarlier: Bool) { transcript?.noteWheel(towardEarlier: towardEarlier) }

        deinit {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }

        #if DEBUG
        override func layout() {
            super.layout()
            if window != nil { DebugTranscriptWheel.reporter = self }
        }
        #endif

        func clampScrolling() {
            #if DEBUG
            DebugTranscriptWheel.reporter = self
            #endif
            guard let scrollView = enclosingScrollView else { return }
            if scrollView.verticalScrollElasticity != .none {
                scrollView.verticalScrollElasticity = .none
            }
            transcript?.restoreMeasured = { [weak scrollView] drift in
                guard let scrollView else { return false }
                let clip = scrollView.contentView
                var bounds = clip.bounds
                bounds.origin.y += clip.isFlipped ? drift : -drift
                let target = clip.constrainBoundsRect(bounds).origin
                guard abs(target.y - clip.bounds.origin.y) >= 0.5 else { return false }
                clip.scroll(to: target)
                scrollView.reflectScrolledClipView(clip)
                return true
            }
        }
    }
}
#endif
