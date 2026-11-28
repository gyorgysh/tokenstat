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
    var git: GitStatus? = nil
    var onBranchChanged: (() async -> Void)? = nil
    var onReviewChanges: ((String?) -> Void)? = nil
    var onReviewTurnChanges: ((ChatTurnChanges, String?) -> Void)? = nil
    var onNewChat: (() -> Void)? = nil
    @Binding var showingOverview: Bool
    var isActive = true
    var loadsWorkspace = true
    var showsConversationToolbarActions = true
    @State private var draftSelection = NSRange(location: 0, length: 0)
    @State private var scrollTarget: String?
    @State private var follow = TranscriptFollowState()
    @State private var window = TranscriptWindow()
    @State private var settleMood: PersonaMood?
    @State private var settleTaskID = UUID()
    @State private var settledPresentation: ChatPresentationIdentity?
    @State private var settledSelection: ChatReadingIdentity?
    @State private var followPulse = 0
    /// Last instant (non-animated) pin. A scrollTo on a lazy stack walks
    /// every row in between, so silent pins from the settle loop, structural
    /// changes, and pulses share one ~150ms gate, same as the growth repins.
    /// Animated pins (a jump, an approval card) always go through.
    @State private var lastSilentPinAt = Date.distantPast
    @State private var measuredTail = TranscriptMeasuredTail()
    #if os(macOS)
    @State private var exactRows = TranscriptExactRows()
    #endif
    @State private var rowMounts = TranscriptRowMounts()
    @State private var measuringRows = false
    @State private var olderOffset = 0
    @State private var sliceAnchor: [String] = []
    @State private var paneDropTargeted = false
    @State private var transcriptDropTargeted = false
    @State private var dropPresentation: UInt64 = 0
    @State private var composerDropTargeted = false
    @State private var pins = PinnedWorkStore.shared
    @State private var showingHandoff = false
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
                    ChatBackdropMenu()
                }
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
                ChatPaneOpening()
            }
            }
            .transformEnvironment(\.personaMotionAllowed) { $0 = $0 && !showingOverview && isActive }
            .chatBackdrop(active: isActive && !showingOverview && model.selected != nil, working: model.busy,
                          lane: ReadingRoom.laneWidth)
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
        .task(id: "\(workspaceID)|\(git?.branch ?? "")|\(model.busy)|\(isActive)") {
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
        .onReceive(NotificationCenter.default.publisher(for: DebugUIHooks.keyRequested)) { note in
            guard isActive, let command = note.object as? String else { return }
            if command == "clear-draft" { model.draft = ""; return }
            if command == "update-prompt" {
                if let chat = model.selected, var backend = model.backend(for: chat.backend) {
                    backend.updateAvailable = true
                    backend.latestVersion = backend.latestVersion.map { $0 + "-preview" } ?? "preview"
                    model.agentUpdatePrompt = AgentUpdatePrompt(backend: backend) {}
                }
                return
            }
            if command == "earlier" { window.requestArchivePage(); return }
            if command == "heights" {
                let known = TranscriptProbe.shared.measuredHeights
                let lines = visibleItems.map { item -> String in
                    let kind = String(describing: item.kind).prefix(while: { $0 != "(" })
                    return "\(kind)\t\(Int(item.tailHeightFloor))\t\(Int(known[item.id] ?? -1))\t\(item.id)"
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-heights.tsv")
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                return
            }
            if command == "track" { TranscriptProbe.shared.trackedRow = window.anchor?.id; return }
            if command.hasPrefix("where") {
                let anchor = window.anchor
                TranscriptHoldTrace.note("where \(command.dropFirst(5)) id=\(anchor?.id ?? "none") top=\(Int(anchor?.top ?? 0)) height=\(Int(anchor?.height ?? 0)) rows=\(model.displayItems.count) built=\(visibleItems.count) hidden=\(hiddenAboveCount) later=\(sliceOffset) pinned=\(follow.pinned)")
                return
            }
            guard command.hasPrefix("type:") else { return }
            model.draft += String(command.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\n")
        }
        #endif
        .onChange(of: isActive) { was, active in
            guard active, !was, model.canDiscardPagedHistory, !model.busy,
                  !TranscriptSlice.measuresWhole(visibleItems) else { return }
            Task { await model.reopenAtLatest() }
        }
        .modifier(ChatFileTransferControls(model: model))
        .modifier(ChatCacheWarningAlert(model: model, isActive: isActive))
        .modifier(AgentUpdatePromptSheet(model: model, isActive: isActive))
        .alert(L10n.text("apple.chatview.chat_unavailable.a45aae80"), isPresented: Binding(
            get: { isActive && model.error != nil },
            set: { if !$0 && isActive { model.error = nil } }
        )) {
            Button(L10n.text("apple.chatview.ok.565339bc"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    /// The older rows in a lazy stack, which sizes the rows it has not built
    /// by estimate. The iPhone's transcript, and the Mac's with
    /// `debug.lazyHead` set.
    private func lazyHead(_ rows: ArraySlice<ChatDisplayItem>, chat: ChatConversation,
                          spinning: String?, liveRowID: String?) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            transcriptHeader(chat)
            ForEach(rows) { item in
                transcriptRow(item, chat: chat, spinning: spinning, isLive: item.id == liveRowID)
                    .allowsHitTesting(!follow.scrolling)
                    .transcriptRowMount(in: rowMounts, id: item.id, window: window)
                    .id(item.id)
            }
        }
        // A lazy stack that gives all its rows to the measured stack below
        // keeps the size it estimated for them, and only lets it go as a
        // scroll makes it measure again: coming back to a chat read far
        // back, hundreds of points of nothing melted away above the reader
        // as they started to scroll. A new stack starts at its true size.
        .id(rows.isEmpty)
    }

    #if os(macOS)
    private static var exactHead: Bool {
        #if DEBUG
        return !UserDefaults.standard.bool(forKey: "debug.lazyHead")
        #else
        return true
        #endif
    }
    #endif

    @ViewBuilder
    private func transcriptHeader(_ chat: ChatConversation) -> some View {
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
        let rows = visibleItems
        let spinning = TranscriptFollow.spinningRow(rows)
        let split = measuredTail.split(rows, generation: model.selectionGeneration,
                                      streaming: model.busy, docked: follow.pinned || follow.settling)
        let liveRowID = model.busy && sliceOffset == 0 && !model.isShowingCachedTranscript ? rows.last?.id : nil
        let presentation = ChatPresentationIdentity(reading: model.readingIdentity, active: isActive)
        #if os(macOS)
        let verticalPadding = Theme.Space.m
        #else
        let verticalPadding = Theme.Space.xl
        #endif
        ScrollViewReader { proxy in
            let scroll = ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    #if os(macOS)
                    if Self.exactHead {
                        let _ = exactRows.setRows(split.lazy, generation: model.selectionGeneration)
                        TranscriptExactHead(items: split.lazy, rows: exactRows) {
                            transcriptHeader(chat)
                        } row: { item in
                            transcriptRow(item, chat: chat, spinning: spinning, isLive: item.id == liveRowID)
                                .allowsHitTesting(!follow.scrolling)
                                .transcriptRowMount(in: rowMounts, id: item.id, window: window)
                                .id(item.id)
                        } measure: { item in
                            transcriptRow(item, chat: chat, spinning: spinning, isLive: false)
                        }
                    } else {
                        lazyHead(split.lazy, chat: chat, spinning: spinning, liveRowID: liveRowID)
                    }
                    #else
                    lazyHead(split.lazy, chat: chat, spinning: spinning, liveRowID: liveRowID)
                    #endif
                    if split.measured.count > 1 {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            ForEach(split.measured.dropLast()) { item in
                                transcriptRow(item, chat: chat, spinning: spinning, isLive: item.id == liveRowID)
                                    .allowsHitTesting(!follow.scrolling)
                                    .transcriptRowMount(in: rowMounts, id: item.id, window: window)
                                    .id(item.id)
                            }
                        }
                    }
                    if let item = split.measured.last {
                        transcriptRow(item, chat: chat, spinning: spinning, isLive: item.id == liveRowID)
                            .allowsHitTesting(!follow.scrolling)
                            .transcriptRowMount(in: rowMounts, id: item.id, window: window)
                            .id(item.id)
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
                .coordinateSpace(name: TranscriptFollow.contentSpaceName)
                .allowsHitTesting(!model.isShowingCachedTranscript)
                .environment(\.streamingWordsPaused, follow.showJump || sliceOffset > 0)
                .onChange(of: follow.showJump || sliceOffset > 0, initial: true) { _, away in
                    LiveMarkdownReader.setAway(away, for: follow)
                }
                .onDisappear { LiveMarkdownReader.remove(follow) }
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
                TranscriptProbe.shared.noteOffset(top: metrics.distanceFromTop, bottom: metrics.distanceFromBottom,
                                                  content: metrics.contentHeight)
                TranscriptProbe.shared.pinned = follow.pinned
                TranscriptProbe.shared.scrolling = follow.scrolling
                TranscriptProbe.shared.built = rows.count
                #endif
                follow.sliceHidesNewest = sliceOffset > 0
                follow.note(metrics)
                window.followingEnd = (follow.pinned || follow.settling) && sliceOffset == 0
                window.note(metrics)
                #if os(macOS)
                if Self.exactHead {
                    exactRows.update(top: metrics.distanceFromTop - verticalPadding, viewport: metrics.viewportHeight)
                }
                #endif
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
                    follow.freeze()
                }
            }
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
                while model.openingConversation {
                    if model.isShowingCachedTranscript,
                       !(model.currentReference.map(ChatReadingStore.shared.hasRequest(for:)) ?? false) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, settleTaskID == ticket,
                          presentation.reading == model.readingIdentity else { return }
                }
                guard !Task.isCancelled, presentation.reading == model.readingIdentity else { return }
                if await restoreReadingPlace(proxy) != .unavailable { return }
                guard !Task.isCancelled, settleTaskID == ticket,
                      presentation.reading == model.readingIdentity else { return }
                #if os(macOS)
                await warmLazyEstimates(proxy, ticket: ticket, presentation: presentation)
                #endif
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
        .id(ChatReadingIdentity(reference: presentation.reading.reference,
                                generation: presentation.reading.generation))
        #endif
        }
    }

    #if os(macOS)
    /// Let the lazy stack settle its estimates before the reader scrolls.
    ///
    /// Rows above the measured tail carry estimated heights, and each change
    /// of offset makes the stack measure a few more of them. On a reader's
    /// first scroll after opening, that is the content above the viewport
    /// growing or shrinking by a screen in the middle of their gesture. Move
    /// the viewport up and back a few times while the opening cover is still
    /// up, so most of them settle here. The settle loop after this puts the
    /// end back under the viewport before anything is revealed. Measured on
    /// a long chat this halved the first scroll's swing; a short slice
    /// avoids it entirely by being measured whole.
    private func warmLazyEstimates(_ proxy: ScrollViewProxy, ticket: UUID,
                                   presentation: ChatPresentationIdentity) async {
        guard !TranscriptSlice.measuresWhole(visibleItems),
              settledSelection != Self.selectionKey(presentation),
              let move = window.restoreMeasured else { return }
        for _ in 0..<Self.warmMoves {
            guard !Task.isCancelled, settleTaskID == ticket,
                  presentation.reading == model.readingIdentity, !follow.abandoned else { return }
            guard move(-Self.warmDistance) else { return }
            try? await Task.sleep(for: .milliseconds(20))
            _ = move(Self.warmDistance)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let warmMoves = 6
    private static let warmDistance: CGFloat = 60
    #endif

    private static func selectionKey(_ presentation: ChatPresentationIdentity) -> ChatReadingIdentity {
        ChatReadingIdentity(reference: presentation.reading.reference, generation: presentation.reading.generation)
    }

    private func prepareTranscript(_ presentation: ChatPresentationIdentity, rowCount: Int) {
        guard presentation.reading == model.readingIdentity else { return }
        #if os(macOS)
        window.release()
        window.clearRowFrames()
        window.followingEnd = true
        window.releaseFollow = { [follow] in follow.releaseForReaderWheel() }
        window.rowHeightNoted = { [exactRows] id, height in exactRows.noteHeight(id, height) }
        window.prepareScroll = { [exactRows] id in !Self.exactHead || exactRows.ensureDrawn(id) }
        exactRows.shift = { [window] delta in
            _ = window.restoreMeasured?(delta)
            window.rowsAboveResized(by: delta)
            window.coveredLayoutMoved()
        }
        exactRows.canShift = { [window] in !window.followingEnd && !window.isRestoringPage }
        window.canPage = { [follow] in !follow.scrolling }
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
        .transcriptRowFrame(
            item.id,
            watched: !follow.scrolling && (measuringRows || !follow.atEnd)
        )
    }

    private static let settleFrames = 24

    private var visibleItems: [ChatDisplayItem] {
        TranscriptSlice.items(model.transcriptItems, olderOffset: sliceOffset)
    }

    private var hiddenAboveCount: Int {
        TranscriptSlice.hiddenAbove(count: model.transcriptItems.count, olderOffset: sliceOffset)
    }

    private var sliceOffset: Int {
        if olderOffset > 0, !sliceAnchor.isEmpty {
            return TranscriptSlice.holding(sliceAnchor, in: model.transcriptItems, current: olderOffset)
        }
        return TranscriptSlice.clampOffset(olderOffset, count: model.transcriptItems.count)
    }

    private func showNewest() {
        applySlice(0)
    }

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

    private func revealEarlier() {
        guard hiddenAboveCount > 0 else {
            window.hasHiddenEarlierRows = false
            window.ask()
            return
        }
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

    private func revealLater() {
        guard sliceOffset > 0 else {
            window.hasHiddenLaterRows = false
            return
        }
        let room = window.slideRoom(in: visibleItems.map(\.id), later: true)
        guard room > 0 else { return }
        window.holdPlace("slide-later")
        applySlice(
            TranscriptSlice.revealingLater(
                count: model.transcriptItems.count, olderOffset: sliceOffset, limit: room
            )
        )
    }

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

    private static let chaseFrames = 24

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
        guard isActive else { return }
        if id != TranscriptFollow.bottomID {
            model.revealRow(id)
            applySlice(TranscriptSlice.revealing(id, in: model.transcriptItems))
        } else {
            showNewest()
        }
        let animate = animated && !reduceMotion
        #if os(macOS)
        if id != TranscriptFollow.bottomID, Self.exactHead, !exactRows.ensureDrawn(id) {
            DispatchQueue.main.async { scrollTo(id, proxy, animated: animated) }
            return
        }
        #endif
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

    private func restoreReadingPlace(_ proxy: ScrollViewProxy) async -> TranscriptReading.Restoration {
        guard let reference = model.currentReference,
              let mark = ChatReadingStore.shared.takeRequest(for: reference) else { return .unavailable }
        return await TranscriptReading.restore(mark, reference: reference, model: model, follow: follow) { id, point in
            placeRow(id, proxy, at: point)
        }
    }

    private func placeRow(_ id: String, _ proxy: ScrollViewProxy, at point: UnitPoint) {
        guard isActive else { return }
        applySlice(TranscriptSlice.holding([id], in: model.transcriptItems, current: 0))
        follow.markDrivenInstant()
        func scroll() {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(id, anchor: point)
            }
        }
        #if os(macOS)
        if Self.exactHead, !exactRows.ensureDrawn(id) {
            DispatchQueue.main.async { scroll() }
            return
        }
        #endif
        scroll()
    }

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

    private func submit(from chat: ChatConversation, sendNow: Bool = false, cacheConfirmed: Bool = false,
                        updateAnswered: Bool = false) {
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
        if sendNow {
            guard let item = model.enqueue(text, atFront: true) else { return }
            model.clearDraft()
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
        if !updateAnswered, model.updatingAgentID == nil,
           AgentUpdatePrompt.isDue(model.backend(for: chat.backend), peer: model.peer),
           let backend = model.backend(for: chat.backend) {
            model.agentUpdatePrompt = AgentUpdatePrompt(backend: backend) {
                guard model.selected?.id == chat.id, let current = model.selected else { return }
                submit(from: current, cacheConfirmed: cacheConfirmed, updateAnswered: true)
            }
            return
        }
        if !cacheConfirmed,
           !ChatPromptCacheRule.isSuppressed(ChatPromptCacheRule.idleSuppressedKey),
           let idle = ChatPromptCacheRule.idle(chat, nowMs: ChatModel.nowMs),
           let cache = ChatPromptCacheRule.cache(chat) {
            askBeforeColdSend(chat, text: text, idleMs: idle, tokens: cache.tokens)
            return
        }
        guard model.holdDraftForSending(text) else { return }
        showNewest()
        follow.jump()
        followPulse += 1
        Task { await model.sendFromComposer() }
    }

    private func askBeforeColdSend(_ chat: ChatConversation, text: String, idleMs: Int64, tokens: UInt64) {
        let peer = model.peer
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
            submit(from: current, cacheConfirmed: true, updateAnswered: true)
        }
        model.cacheWarning = ChatCacheWarning(kind: .idle(idleMs: idleMs, startNew: startNew),
                                              tokens: tokens, proceed: proceed)
    }

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
#if DEBUG
@MainActor
enum DebugTranscriptWheel {
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
            // A negative tail glides: the same decaying speed a flick coasts
            // at, sent as the gesture still moving, because AppKit ignores a
            // momentum phase that no real trackpad started.
            if momentum < 0 {
                var value = Double(points)
                for _ in 0..<(-momentum) {
                    value *= 0.92
                    let delta = Int32(value.rounded())
                    guard delta != 0 else { break }
                    send(delta, phase: 2, momentum: 0, at: location)
                    try? await Task.sleep(for: .milliseconds(16))
                }
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

        private var picture: NSView?

        func cover() {
            uncover()
            guard window != nil, !isHiddenOrHasHiddenAncestor, let scroll = enclosingScrollView,
                  let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return }
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            let image = NSImage(size: scroll.bounds.size)
            image.addRepresentation(rep)
            let view = NSView(frame: scroll.bounds)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(Theme.background).cgColor
            let content = CALayer()
            content.frame = view.bounds
            content.contents = image
            content.contentsGravity = .resize
            view.layer?.addSublayer(content)
            view.autoresizingMask = [.width, .height]
            scroll.addSubview(view, positioned: .above, relativeTo: nil)
            picture = view
        }

        func uncover() {
            picture?.removeFromSuperview()
            picture = nil
        }

        func clampScrolling() {
            #if DEBUG
            DebugTranscriptWheel.reporter = self
            #endif
            guard let scrollView = enclosingScrollView else { return }
            if scrollView.verticalScrollElasticity != .none {
                scrollView.verticalScrollElasticity = .none
            }
            guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
            transcript?.cover = { [weak self] in self?.cover() }
            transcript?.uncover = { [weak self] in self?.uncover() }
            transcript?.restoreMeasured = { [weak self] drift in
                guard let self, self.window != nil, let scrollView = self.enclosingScrollView else { return false }
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

// The boundary between eager and lazy rows changes their SwiftUI identity.
// Keep it fixed while an existing reply grows.
final class TranscriptMeasuredTail {
    struct Key: Equatable {
        let generation: UInt64
        let count: Int
        let first: String?
        let last: String?
        let whole: Bool
    }

    private var key: Key?
    private var start = 0

    func split(_ rows: [ChatDisplayItem], generation: UInt64, streaming: Bool, docked: Bool)
        -> (lazy: ArraySlice<ChatDisplayItem>, measured: ArraySlice<ChatDisplayItem>) {
        // Rows arriving above the reader (an earlier page) keep a whole
        // slice whole while it stays short: moving every row into the
        // lazy stack under the page's hold is what lost the held row.
        let sameReading = key?.generation == generation
        let whole = docked || (sameReading && key?.whole == true)
        let next = Key(generation: generation, count: rows.count, first: rows.first?.id, last: rows.last?.id,
                       whole: whole)
        if let key, sameReading, key.first == rows.first?.id, rows.count >= key.count, start <= rows.count {
            self.key = next
            return TranscriptSlice.split(rows, measuredFrom: start)
        }
        if next != key {
            start = TranscriptSlice.measuredTailStart(rows, whole: whole)
            key = next
        }
        return TranscriptSlice.split(rows, measuredFrom: start)
    }
}

#if os(macOS)
/// The older rows of a transcript, at their real heights.
///
/// A lazy stack sizes every row it has not built with one guess, and the
/// rows of a chat are very different sizes: a one-line step is 24 points, a
/// usage line 14, a plan 170, a picture 300, a reply a screen. Reading back
/// built them, the guesses were corrected, and the conversation's height
/// changed under the scrollbar by hundreds of points a gesture.
///
/// Here only the rows near the reader are drawn. Everything above them is
/// one empty space and everything below another, each exactly as tall as
/// the rows it stands for: measured heights for rows that have been drawn
/// or measured, an estimate (`estimatedHeight`) for the rest. Rows about to
/// be drawn are measured out of sight first, so a row arriving on screen
/// changes nothing, and a space above the reader that changes size moves
/// the view by the same amount in the same update.
@MainActor @Observable
final class TranscriptExactRows {
    private(set) var firstDrawn: String?
    private(set) var lastDrawn: String?
    private(set) var measuring: [String] = []
    private(set) var revision = 0

    @ObservationIgnored var shift: ((CGFloat) -> Void)?
    @ObservationIgnored var canShift: (() -> Bool)?

    @ObservationIgnored private var heights: [String: CGFloat] = [:]
    @ObservationIgnored private var ids: [String] = []
    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private var sizes: [CGFloat] = []
    @ObservationIgnored private var tops: [CGFloat] = [0]
    @ObservationIgnored private var stale = true
    @ObservationIgnored private var base: CGFloat = 40
    @ObservationIgnored private var lastTop: CGFloat?
    @ObservationIgnored private var lastViewport: CGFloat = 0
    @ObservationIgnored private var generation: UInt64?

    static let spacing = Theme.Space.m
    /// How far beyond the screen rows are drawn, in screens. Every drawn
    /// row reports where it is on every frame of a scroll, so this is kept
    /// close to what a lazy stack keeps built.
    private static let ahead: CGFloat = 0.75
    private static let measuredAbove: CGFloat = 2.5
    private static let measuredBelow: CGFloat = 1
    private static let measuredMost = 40

    func setRows(_ items: ArraySlice<ChatDisplayItem>, generation: UInt64) {
        if generation != self.generation {
            self.generation = generation
            heights.removeAll()
            lastTop = nil
            baseKnown = false
            stale = true
        }
        if items.count != ids.count || items.first?.id != ids.first || items.last?.id != ids.last
            || !zip(items, ids).allSatisfy({ $0.id == $1 }) {
            ids = items.map(\.id)
            index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            sizes = items.map { heights[$0.id] ?? Self.estimatedHeight($0) }
            stale = true
            rowsVersion &+= 1
        }
    }

    @ObservationIgnored private(set) var rowsVersion = 0

    var drawn: ClosedRange<Int> {
        guard !ids.isEmpty else { return 0...0 }
        let last = ids.count - 1
        if let lower = firstDrawn.flatMap({ index[$0] }), let upper = lastDrawn.flatMap({ index[$0] }),
           lower <= upper {
            return lower...upper
        }
        return max(0, last - 30)...last
    }

    func spaces(around drawn: ClosedRange<Int>) -> (above: CGFloat, below: CGFloat) {
        guard !ids.isEmpty else { return (0, 0) }
        rebuildTops()
        let above = drawn.lowerBound > 0 ? tops[drawn.lowerBound] - Self.spacing : 0
        let below = drawn.upperBound < ids.count - 1
            ? tops[ids.count] - Self.spacing - tops[drawn.upperBound + 1] : 0
        return (max(0, above), max(0, below))
    }

    func ensureDrawn(_ id: String) -> Bool {
        guard let row = index[id] else { return true }
        if drawn.contains(row) { return true }
        rebuildTops()
        let reach = max(lastViewport, 600) * Self.ahead
        let want = rows(from: tops[row] + base - reach, to: tops[row] + base + reach)
        firstDrawn = ids[min(want.lowerBound, row)]
        lastDrawn = ids[max(want.upperBound, row)]
        return false
    }

    func noteMeasured(_ id: String, _ height: CGFloat) {
        guard height > 0, let row = index[id] else { return }
        heights[id] = height
        let delta = height - sizes[row]
        guard abs(delta) > 0.5 else { return }
        rebuildTops()
        let above = lastTop.map { tops[row] + base < $0 } ?? false
        sizes[row] = height
        stale = true
        revision &+= 1
        if above, canShift?() != false { shift?(delta) }
    }

    func noteHeight(_ id: String, _ height: CGFloat) {
        guard height > 0, let row = index[id] else { return }
        heights[id] = height
        guard abs(sizes[row] - height) > 0.5 else { return }
        sizes[row] = height
        stale = true
    }

    func noteHeaderBottom(_ bottom: CGFloat) {
        let next = bottom + Self.spacing
        let delta = next - base
        let reading = lastTop.map { $0 > base } ?? false
        base = next
        guard abs(delta) > 0.5, reading, baseKnown else {
            baseKnown = true
            return
        }
        if canShift?() != false { shift?(delta) }
    }
    @ObservationIgnored private var baseKnown = false

    func update(top: CGFloat, viewport: CGFloat) {
        lastTop = top
        lastViewport = viewport
        guard !ids.isEmpty, viewport > 0 else { return }
        rebuildTops()
        let current = drawn
        let want = rows(from: top - viewport * Self.ahead, to: top + viewport * (1 + Self.ahead))
        guard firstDrawn != nil else {
            place(want)
            return
        }
        let need = rows(from: top - viewport * 0.25, to: top + viewport * 1.25)
        if need.lowerBound < current.lowerBound || need.upperBound > current.upperBound
            || need.upperBound < current.lowerBound || need.lowerBound > current.upperBound {
            place(want)
            return
        }
        let near = rows(from: top - viewport * 0.5, to: top + viewport * 1.5)
        if current.lowerBound <= near.lowerBound, current.upperBound >= near.upperBound {
            planMeasuring(around: current)
            return
        }
        // Otherwise move toward `want` a few rows a frame, as a lazy stack
        // builds rows as they arrive. A screen of rows built in one frame
        // was a stall each time the drawn rows moved, and moving them on
        // every frame cost more than it saved.
        //
        // Only into rows already measured out of sight: a row drawn before
        // its height is known changes size where the reader can see the
        // text move. Until the measuring catches up, the range waits.
        let step = Self.rowsPerFrame
        var lower = current.lowerBound, upper = current.upperBound
        var added = 0
        while lower > want.lowerBound, added < step, heights[ids[lower - 1]] != nil {
            lower -= 1
            added += 1
        }
        if want.lowerBound > lower + step * 2 { lower = min(want.lowerBound, need.lowerBound) }
        added = 0
        while upper < want.upperBound, added < step, heights[ids[upper + 1]] != nil {
            upper += 1
            added += 1
        }
        if want.upperBound < upper - step * 2 { upper = max(want.upperBound, need.upperBound) }
        place(lower...upper)
    }

    private func place(_ range: ClosedRange<Int>) {
        let first = ids[range.lowerBound], last = ids[range.upperBound]
        if first != firstDrawn { firstDrawn = first }
        if last != lastDrawn { lastDrawn = last }
        planMeasuring(around: range)
    }

    private static let rowsPerFrame = 8

    private func planMeasuring(around drawn: ClosedRange<Int>) {
        var next: [String] = []
        var covered: CGFloat = 0
        var row = drawn.lowerBound - 1
        while row >= 0, next.count < Self.measuredMost, covered < lastViewport * Self.measuredAbove {
            covered += sizes[row]
            if heights[ids[row]] == nil { next.append(ids[row]) }
            row -= 1
        }
        covered = 0
        var below = 0
        row = drawn.upperBound + 1
        while row < ids.count, below < Self.measuredMost / 2, covered < lastViewport * Self.measuredBelow {
            covered += sizes[row]
            if heights[ids[row]] == nil { next.append(ids[row]); below += 1 }
            row += 1
        }
        if next != measuring { measuring = next }
    }

    private func rows(from: CGFloat, to: CGFloat) -> ClosedRange<Int> {
        let last = ids.count - 1
        let lower = min(last, max(0, rowAt(from - base)))
        let upper = min(last, max(lower, rowAt(to - base)))
        return lower...upper
    }

    private func rowAt(_ offset: CGFloat) -> Int {
        var low = 0, high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid + 1] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func rebuildTops() {
        guard stale else { return }
        stale = false
        var tops = [CGFloat](repeating: 0, count: sizes.count + 1)
        for row in sizes.indices {
            tops[row + 1] = tops[row] + sizes[row] + Self.spacing
        }
        self.tops = tops
    }

    static func estimatedHeight(_ item: ChatDisplayItem) -> CGFloat {
        func prose(_ text: String, padding: CGFloat) -> CGFloat {
            var lines = 0
            var run = 0
            for unit in text.utf8 {
                if unit == 10 { lines += 1 + run / 105; run = 0 } else { run += 1 }
            }
            lines += 1 + run / 105
            return CGFloat(lines) * 21 + padding
        }
        switch item.kind {
        case let .assistant(text, _): return prose(text, padding: item.part?.isFirst == false ? 16 : 40)
        case let .user(text): return prose(text, padding: 30)
        case let .thinking(text), let .failed(text): return min(prose(text, padding: 20), 120)
        case .group, .tool, .turnSeparator: return 24
        case .usage: return 14
        case .changes: return 100
        case let .plan(steps): return 40 + CGFloat(steps.count) * 26
        case .attachment: return 300
        case .edit, .approval, .question: return 120
        case .handoff: return 75
        }
    }
}

private struct TranscriptExactHead<Header: View, Row: View, Measure: View>: View {
    let items: ArraySlice<ChatDisplayItem>
    let rows: TranscriptExactRows
    @ViewBuilder let header: () -> Header
    let row: (ChatDisplayItem) -> Row
    let measure: (ChatDisplayItem) -> Measure

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptExactRows.spacing) {
            header()
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(TranscriptFollow.contentSpaceName)).maxY
                } action: { bottom in
                    rows.noteHeaderBottom(bottom)
                }
            TranscriptExactSpace(rows: rows, above: true, version: rows.rowsVersion)
            TranscriptExactDrawn(items: items, rows: rows, row: row)
            TranscriptExactSpace(rows: rows, above: false, version: rows.rowsVersion)
        }
        .background(alignment: .topLeading) {
            TranscriptExactMeasuring(items: items, rows: rows, measure: measure)
        }
    }
}

private struct TranscriptExactSpace: View {
    let rows: TranscriptExactRows
    let above: Bool
    let version: Int

    var body: some View {
        let _ = rows.revision
        let spaces = rows.spaces(around: rows.drawn)
        let height = above ? spaces.above : spaces.below
        if height > 0 {
            Color.clear.frame(height: height)
        }
    }
}

private struct TranscriptExactDrawn<Row: View>: View {
    let items: ArraySlice<ChatDisplayItem>
    let rows: TranscriptExactRows
    let row: (ChatDisplayItem) -> Row

    var body: some View {
        if !items.isEmpty {
            let drawn = rows.drawn
            let lower = items.startIndex + drawn.lowerBound
            let upper = min(items.endIndex - 1, items.startIndex + drawn.upperBound)
            if lower <= upper {
                ForEach(items[lower...upper]) { item in
                    row(item)
                }
            }
        }
    }
}

private struct TranscriptExactMeasuring<Measure: View>: View {
    let items: ArraySlice<ChatDisplayItem>
    let rows: TranscriptExactRows
    let measure: (ChatDisplayItem) -> Measure

    var body: some View {
        let wanted = Set(rows.measuring)
        VStack(alignment: .leading, spacing: 0) {
            if !wanted.isEmpty {
                ForEach(items.filter { wanted.contains($0.id) }) { item in
                    measure(item)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            rows.noteMeasured(item.id, height)
                        }
                }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
