// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import SwiftUI

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
    /// Launcher entry: skip the list and land in the conversation worth
    /// returning to, creating the first one when this folder has none.
    var openConversationOnAppear = false

    @State private var model = ChatModel()
    @State private var loaded = false
    /// The conversation being read, shown in place of the list.
    ///
    /// Not a push, and that is the point. A pushed screen outlives the screen
    /// that pushed it: on the iPad this list lives in a split view's detail
    /// column, and choosing another sidebar row destroys this view while the
    /// stack keeps holding the thread, which then sits on top of the page that
    /// just opened. Nothing outside the stack can pop it, and the stack cannot
    /// be reached: `.id` does not rebuild a split view's detail column and
    /// emptying a bound path does not reach this kind of push. `PullsView`
    /// never had the bug because it swaps its detail in place, so this does
    /// the same, and the state goes away with the view that owns it.
    @State private var opened: ChatConversation?
    @State private var pendingDelete: ChatConversation?
    /// The launcher may skip the list once. Back from the thread must still
    /// reach the list rather than immediately pushing the same chat again.
    @State private var didOpenConversation = false

    private var place: String { folderName.isEmpty ? "this folder" : folderName }

    var body: some View {
        if let opened {
            ClientChatThread(
                model: model,
                chatID: opened.id,
                folderName: folderName,
                hostName: hostName,
                onBack: { self.opened = nil }
            )
        } else {
            list
        }
    }

    private var list: some View {
        ClientCardList(
            title: "Chat",
            errorMessage: model.error.map { ClientTunnelCopy.display($0, host: hostName) },
            isLoaded: loaded,
            isEmpty: model.chats.isEmpty,
            emptyText: "Start a chat",
            emptyArt: .chat(seed: model.defaultFaceSeed),
            emptyMessage: "Ask an agent to explore, plan, or work in \(place).",
            emptyActionTitle: "New chat",
            emptyActionIcon: .create,
            emptyAction: { Task { await create() } },
            refreshKey: "workspace-chat-\(workspaceID)",
            reload: { await reload() }
        ) {
            ForEach(model.chats) { chat in
                Button {
                    opened = chat
                } label: {
                    row(chat)
                }
                .buttonStyle(.plain)
                .clientCardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) { pendingDelete = chat }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", .create) { Task { await create() } }
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete chat", role: .destructive) {
                if let chat = pendingDelete {
                    Task { await model.remove(chat) }
                }
                pendingDelete = nil
            }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The transcript stays on \(hostName.isEmpty ? "the computer" : hostName) until you delete it. This cannot be undone.")
        }
        .task {
            await reload()
            if openConversationOnAppear, !didOpenConversation {
                didOpenConversation = true
                if let recent = model.mostRecent {
                    await model.select(recent)
                    opened = recent
                } else {
                    await create()
                }
            }
        }
    }

    private func row(_ chat: ChatConversation) -> some View {
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
                        .lineLimit(1)
                }
                Text(rowDetail(chat))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
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
        let mode = chat.mode == "plan" ? "Plan" : "Execute"
        return "\(agent) · \(mode)"
    }

    private func reload() async {
        await model.load(workspaceID: workspaceID, peer: peer, selectFirst: false)
        loaded = true
    }

    private func create() async {
        await model.create()
        opened = model.selected
    }
}

/// One conversation: setup, transcript, glass composer.
struct ClientChatThread: View {
    @Bindable var model: ChatModel
    let chatID: String
    let folderName: String
    let hostName: String
    /// How to leave, when this is shown in place of the chat list rather than
    /// pushed on top of it. `PullDetailView` takes the same closure for the
    /// same reason.
    var onBack: (() -> Void)?
    @State private var draft = ""
    /// A row the transcript should jump to, set by the pending-approval bar.
    @State private var scrollTarget: String?
    @State private var follow = TranscriptFollowState()
    @State private var window = TranscriptWindow()
    @State private var settleMood: PersonaMood?
    /// Bumped on send so the transcript scrolls to the end synchronously,
    /// instead of waiting for the first streamed token to trigger a pin.
    @State private var followPulse = 0
    /// Whether rows are reporting where they are. Set from the scroll
    /// callback as the top of the loaded conversation comes near, so the
    /// geometry readers exist for the stretch that can need an anchor and
    /// nowhere else.
    @State private var measuringRows = false
    @State private var showingSetup = false
    @State private var showingPersonas = false
    @State private var urlDropTargeted = false
    @State private var textDropTargeted = false
    @State private var dataDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chat: ChatConversation? {
        model.chats.first { $0.id == chatID } ?? model.selected
    }

    var body: some View {
        VStack(spacing: 0) {
            if let chat {
                transcript(chat)
                    .overlay {
                        if dropExperienceVisible {
                            ChatDropExperience(seed: model.faceSeed)
                        }
                    }
                // Same rule as the Mac: a blocked turn takes the composer's
                // place. On a phone this matters more, not less, because the
                // card scrolls out of a short viewport in one streamed
                // paragraph.
                if model.approvals.isEmpty {
                    ClientChatComposer(
                        model: model,
                        chat: chat,
                        draft: $draft,
                        attachments: model.attachments,
                        previews: model.attachmentPreviews,
                        running: model.busy,
                        placeholder: "Ask about \(folderName.isEmpty ? "this folder" : folderName)",
                        onSend: { submit(from: chat) },
                        onStop: { Task { await model.stop() } },
                        onAttach: { item in await model.attach(item) },
                        onRemove: { model.removeAttachment($0) },
                        onOpenSetup: { showingSetup = true },
                        onDropURLs: { urls in
                            Task { await receive(ChatInbox.drops(from: urls)) }
                        },
                        onDropText: { items in
                            Task { await receive(items.map(ChatInboxDrop.text)) }
                        },
                        onDropData: { items in
                            Task { await receive(items.compactMap(ChatInbox.imageDrop(from:))) }
                        },
                        onDropTargeted: { composerDropTargeted = $0 }
                    )
                } else {
                    ChatApprovalBar(
                        approvals: model.approvals,
                        resolve: { approval, choice in
                            Task { await model.resolve(approval, choice: choice) }
                        },
                        showInTranscript: { approval in
                            scrollTarget = "approval-\(approval.id)"
                        }
                    )
                }
            } else {
                ClientEmptyState(
                    kind: .nothingYet,
                    title: "This chat is gone",
                    message: "It was deleted on \(hostName.isEmpty ? "the computer" : hostName).",
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
            Task { await receive(items.map(ChatInboxDrop.text)) }
            return !items.isEmpty
        } isTargeted: { textDropTargeted = $0 }
        .dropDestination(for: Data.self) { items, _ in
            let drops = items.compactMap(ChatInbox.imageDrop(from:))
            Task { await receive(drops) }
            return !drops.isEmpty
        } isTargeted: { dataDropTargeted = $0 }
        .dropDestination(for: URL.self) { items, _ in
            let drops = ChatInbox.drops(from: items)
            Task { await receive(drops) }
            return !drops.isEmpty
        } isTargeted: { urlDropTargeted = $0 }
        .overlay(alignment: .topTrailing) {
            TransientToast(message: $dropNotice, severity: .warning)
                .padding(Theme.Space.m)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropExperienceVisible)
        .navigationTitle(chat?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { ActionIcon.back.label("Chats") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if chat != nil {
                    Button("Setup", .settings) { showingSetup = true }
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            setupSheet
        }
        .sheet(isPresented: $showingPersonas) {
            PersonaEditor(model: model, onClose: { showingPersonas = false })
        }
        .task {
            guard let chat = model.chats.first(where: { $0.id == chatID }) else { return }
            // Already open, with rows on screen. Re-selecting would empty the
            // transcript and read it back, which is this screen blanking and
            // re-scrolling every time it is pushed, including straight after
            // the launcher picked the conversation for you.
            if model.selected?.id != chat.id || model.displayItems.isEmpty {
                await model.select(chat)
            }
            guard !Task.isCancelled else { return }
            if let current = model.chats.first(where: { $0.id == chatID }) {
                ClientChatReadState.shared.markRead(peer: model.peer, chat: current)
            }
        }
        .task(id: chatID) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await model.poll()
            }
        }
        // The host is on the other computer and cannot see this screen. Until
        // it is told, a turn finishing here pushed to this very phone.
        .watching(conversationID: chatID, peer: model.peer)
        .alert("Chat unavailable", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error.map { ClientTunnelCopy.display($0, host: hostName) } ?? "")
        }
    }

    private func transcript(_ chat: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy on purpose. A long conversation is hundreds of rows of
                // markdown, and a plain stack lays out and re-measures every
                // one of them on every update, whether or not it is anywhere
                // near the screen.
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    TranscriptEarlierHeader(model: model) {
                        window.ask(force: true)
                    }
                    ForEach(model.displayItems) { item in
                        ClientChatEventRow(
                            item: item,
                            attachmentData: attachmentData(for: item),
                            attachmentRevision: model.responseAttachmentRevision,
                            defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                            agentLabel: { backend in
                                model.backend(for: backend)?.label ?? backend.capitalized
                            },
                            isPending: pendingApproval(item),
                            resolve: { approval, choice in
                                Task { await model.resolve(approval, choice: choice) }
                            },
                            faceSeed: model.faceSeed,
                            isLive: model.busy && item.id == model.displayItems.last?.id
                        )
                        .equatable()
                        .transcriptRowFrame(item.id, watched: model.hasEarlier && measuringRows)
                    }
                    if let mood = liveMood {
                        ChatWorkingIndicator(seed: model.faceSeed, mood: mood)
                    }
                    TranscriptBottomSentinel()
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)
                .chatScrollContent()
            }
            .scrollDismissesKeyboard(.interactively)
            // Only the bottom. The composer sits right under it and draws
            // its own edge, while the top is where the system's own fade
            // keeps the first "Web search:" chip off the navigation bar.
            .clientHideScrollEdgeEffect(for: .bottom)
            .opacity(transcriptReady ? 1 : 0)
            .overlay {
                if !transcriptReady {
                    TranscriptSkeleton()
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: transcriptReady)
            .chatScrollMetrics { metrics in
                follow.note(metrics)
                // Order matters: the pin is decided from this frame, and the
                // window has to see that decision before it acts on the same
                // frame.
                window.followingEnd = follow.pinned || follow.settling
                window.note(metrics)
            }
            .overlay(alignment: .bottom) {
                if model.approvals.isEmpty {
                    TranscriptFollowPill(
                        showJump: follow.showJump,
                        busy: model.busy,
                        paused: follow.paused,
                        resume: {
                            follow.jump()
                            Task { await returnToLatest(proxy) }
                        },
                        pause: { follow.pause() }
                    )
                }
            }
            .transcriptEarlierPages(model, window: window, proxy: proxy)
            .onChange(of: structureToken) { _, _ in
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: streamToken) { _, _ in
                if !follow.atEnd { pinToLatest(proxy, animated: false) }
            }
            .onChange(of: followPulse) { _, _ in
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: chat.running) { _, _ in
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: model.busy) { was, now in
                settleAfterTurn(was: was, now: now)
            }
            .onChange(of: model.approvals.isEmpty) { _, empty in
                follow.suppressed = !empty
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
            .onAppear {
                follow.suppressed = !model.approvals.isEmpty
                window.nearTopChanged = { measuringRows = $0 }
                installRepin(proxy)
                pinToLatest(proxy, animated: false)
            }
            .task(id: model.selected?.id) {
                // A lazy stack does not know its own height until it has drawn
                // the rows, so the first scroll to the end lands on estimates.
                // Hold the end across the frames the real heights take to
                // arrive: every one of those says the end is far below, and
                // believing one is how a long chat opened in its middle.
                follow.settle(true)
                defer { follow.settle(false) }
                // Same as the Mac: hold the end until the conversation has
                // stopped arriving, not for a fixed count of frames.
                var quiet = 0
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, model.approvals.isEmpty else { return }
                    // Only when it is not already there. Each of these is a
                    // walk over every row between here and the end.
                    if !follow.atEnd { pinToLatest(proxy, animated: false) }
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
                        Button("Personas", .persona) { showingPersonas = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle("Chat setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", .done) { showingSetup = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }

    private var liveMood: PersonaMood? {
        TranscriptFollow.liveMood(
            items: model.displayItems,
            busy: model.busy,
            runningTool: model.isRunningTool,
            waiting: !model.approvals.isEmpty,
            settle: settleMood
        )
    }

    private var structureToken: String {
        TranscriptFollow.structureToken(
            items: model.displayItems,
            busy: model.busy,
            runningTool: model.isRunningTool,
            settle: settleMood
        )
    }

    private var streamToken: Int {
        TranscriptFollow.streamExtent(model.displayItems)
    }

    private func settleAfterTurn(was: Bool, now: Bool) {
        if now {
            settleMood = nil
            return
        }
        guard was else { return }
        if case .failed = model.displayItems.last?.kind {
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
    private var transcriptReady: Bool {
        follow.arrived && !model.openingConversation
    }


    /// Come back to the latest turn, by the cheapest route that works.
    ///
    /// On a window grown by paging back, scrolling there means the lazy stack
    /// resolving every row in between, several times over as the press is
    /// made to land. Reopening on the newest page is one bounded read and
    /// leaves the transcript small enough that the scroll is instant.
    private func returnToLatest(_ proxy: ScrollViewProxy) async {
        if model.displayItems.count > TranscriptWindow.reopenAbove {
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

    /// Let the scroll callback put the viewport back on the end. Weak on the
    /// state, which owns the closure.
    private func installRepin(_ proxy: ScrollViewProxy) {
        let state = follow
        let model = model
        state.repin = { [weak state] in
            guard let state, state.pinned, model.approvals.isEmpty else { return }
            state.markDrivenInstant()
            proxy.scrollTo(TranscriptFollow.bottomID, anchor: .bottom)
        }
    }

    private func pinToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // A pending request owns the view. Streaming text must not scroll it
        // out from under somebody who is reading it to decide.
        guard follow.pinned, model.approvals.isEmpty else { return }
        scrollTo(TranscriptFollow.bottomID, proxy, animated: animated)
    }

    private func scrollTo(_ id: String, _ proxy: ScrollViewProxy, animated: Bool) {
        // Every scroll here is programmatic. Say so, or the frames of the
        // animation read as the reader leaving and unpin mid-flight.
        // Instant pins land on the same frame and only need a short window.
        let animate = animated && !reduceMotion
        follow.markDriven(duration: animate ? 0.4 : 0.08)
        if !animate {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: TranscriptFollow.structureDuration)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func submit(from chat: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attached image is content on its own: text is only mandatory
        // when there is nothing attached.
        guard !text.isEmpty || !model.attachments.isEmpty, !model.busy else { return }
        draft = ""
        // Sending is engaging: follow is the default, so a new turn resumes
        // it even if it was paused before. Pausing again is one tap. The
        // pulse scrolls now; the token pins take over as content arrives.
        follow.jump()
        followPulse += 1
        Task { await model.send(text) }
    }

    private var dropExperienceVisible: Bool {
        urlDropTargeted || textDropTargeted || dataDropTargeted || composerDropTargeted
    }

    private func receive(_ drops: [ChatInboxDrop]) async {
        for drop in drops {
            switch drop {
            case let .attachment(item):
                await model.attach(item)
            case let .text(text):
                draft.append(text)
            case .folder:
                showDropNotice("Attach files, not folders")
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

#endif
