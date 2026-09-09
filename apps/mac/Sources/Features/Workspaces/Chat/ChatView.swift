// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import OSLog
import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel
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
    /// Whether this pane is the one in front.
    ///
    /// The Mac keeps it mounted behind other screens so a transcript and the
    /// place somebody had read to survive a trip to Insights and back. A pane
    /// nobody can see does not poll, and it does not hold the shared model to
    /// a folder that has since been left: it reloads when it comes forward.
    var isActive = true
    /// The composer's words live on the model, keyed to the conversation
    /// rather than to this pane, so leaving and coming back finds them and
    /// switching conversations does not carry them across.
    @State private var draftSelection = NSRange(location: 0, length: 0)
    /// A row the transcript should jump to, set by the pending-approval bar.
    @State private var scrollTarget: String?
    @State private var follow = TranscriptFollowState()
    @State private var window = TranscriptWindow()
    @State private var settleMood: PersonaMood?
    /// Bumped on send so the transcript scrolls to the end synchronously,
    /// instead of waiting for the first streamed token to trigger a pin.
    @State private var followPulse = 0
    /// Last instant (non-animated) pin. A scrollTo on a lazy stack walks
    /// every row in between, so silent pins from the settle loop, structural
    /// changes, and pulses share one ~150ms gate, same as the growth repins.
    /// Animated pins (a jump, an approval card) always go through.
    @State private var lastSilentPinAt = Date.distantPast
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
    @State private var sliceAnchor: String?
    @State private var paneDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
                ToolbarIconButton(systemImage: "plus", help: "New chat") {
                    Task { await model.create() }
                }
            }
            #endif
            if let chat = model.selected {
                transcript(chat)
                    .overlay {
                        if dropExperienceVisible {
                            dropExperience
                        }
                    }
                // A blocked turn takes the composer's place rather than
                // sitting beside it. There is nothing useful to type while an
                // agent is parked, and removing the field is the plainest way
                // to say what the conversation is actually waiting for.
                if model.approvals.isEmpty {
                    if !model.queued.isEmpty {
                        ChatQueueStrip(
                            items: model.queued,
                            ownerID: chat.id,
                            onChange: { item, text in model.updateQueued(item, text: text) },
                            onRemove: { model.removeQueued($0) },
                            onSendNow: { item in
                                showNewest()
                                follow.jump()
                                followPulse += 1
                                Task { await model.sendNow(item) }
                            },
                            onMove: { model.moveQueued(from: $0, to: $1) }
                        )
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.bottom, Theme.Space.s)
                        .frame(maxWidth: .infinity)
                    }
                    ChatComposer(
                        model: model,
                        chat: chat,
                        draft: $model.draft,
                        selection: $draftSelection,
                        attachments: model.attachments,
                        previews: model.attachmentPreviews,
                        running: model.busy,
                        placeholder: model.busy
                            ? "Send after this turn"
                            : "Ask about \(workspaceName ?? "this folder")",
                        onSend: { submit(from: chat) },
                        onSendNow: { submit(from: chat, sendNow: true) },
                        onStop: { Task { await model.stop() } },
                        onAttach: { item in await model.attach(item) },
                        onRemove: { model.removeAttachment($0) },
                        onDropProviders: { providers in
                            Task { await receive(providers) }
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
                    .frame(maxWidth: ReadingRoom.laneWidth)
                    .frame(maxWidth: .infinity)
                }
            } else if model.isReady(for: workspaceID), model.chats.isEmpty {
                empty
                    .overlay {
                        if dropExperienceVisible {
                            dropExperience
                        }
                    }
            } else {
                // Either nothing has been asked yet, or this folder's
                // conversations are known and one is about to be picked.
                // "Start a chat" belongs to neither: it is a promise about a
                // folder nobody has looked in, and it was being made every
                // time this pane was rebuilt.
                ChatPaneOpening()
            }
        }
        .background(Theme.background)
        .onDrop(of: ChatInbox.dropTypes, isTargeted: $paneDropTargeted) { providers in
            Task { await receive(providers) }
            return true
        }
        .overlay(alignment: .topTrailing) {
            TransientToast(message: $dropNotice, severity: .warning)
                .padding(.top, Theme.Space.m)
                .padding(.trailing, Theme.Space.m)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dropExperienceVisible)
        #if os(macOS)
        .onExitCommand {
            if model.busy { Task { await model.stop() } }
        }
        #endif
        #if !os(macOS)
        .navigationTitle(model.selected?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", .create) { Task { await model.create() } }
            }
        }
        #endif
        .task(id: "\(workspaceID)-\(isActive)-\(String(describing: WorkSessionContext.shared.scope))") {
            Logger(subsystem: "ai.tokenstat.tokenstat", category: "chatload")
                .error("view task ws=\(workspaceID) active=\(isActive)")
            guard isActive else { return }
            await model.load(workspaceID: workspaceID)
        }
        // What is on screen, for the notifier. This pane stays mounted behind
        // other destinations, so `isActive` is the part `model.selected`
        // cannot answer on its own.
        #if os(macOS)
        .onChange(of: "\(model.selected?.id ?? "")-\(isActive)", initial: true) { _, _ in
            UserPresence.shared.chatSurface(showing: isActive ? model.selected?.id : nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatAttachmentCachePurged)) { _ in
            model.clearCachedAttachmentMemory()
        }
        .onDisappear {
            UserPresence.shared.chatSurface(showing: nil)
        }
        #endif
        // Unsent words are written a third of a second after the last
        // keystroke. These two are the moments that can arrive sooner.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveDraftNow() }
        }
        .onDisappear { model.saveDraftNow() }
        // And the same fact to the host, which is the one deciding whether a
        // phone hears about this turn.
        .watching(conversationID: model.selected?.id, peer: model.peer, isActive: isActive)
        .task(id: "\(model.selected?.id ?? "")-\(isActive)") {
            guard isActive else { return }
            // A daemon that has just started serves its curated fallbacks
            // while it probes the agent CLIs. Give that a moment and look
            // again, so a chat opened during the race does not keep a
            // half-filled model list until the window is closed.
            try? await Task.sleep(for: .seconds(2))
            await model.refillBackendsIfIncomplete()
            while !Task.isCancelled {
                try? await Task.sleep(for: model.pollInterval)
                guard !Task.isCancelled else { return }
                await model.poll()
            }
        }
        .alert("Chat unavailable", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
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
                    #if !os(macOS)
                    if !model.chats.isEmpty {
                        conversationMenu
                    }
                    #endif
                    if model.displayItems.isEmpty, !chat.running, !model.openingConversation {
                        emptyConversation
                    }
                    TranscriptEarlierHeader(model: model) {
                        window.ask(force: true)
                    }
                    if hiddenAboveCount > 0 {
                        Button("Show \(hiddenAboveCount) earlier messages", .history) {
                            revealEarlier()
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Show earlier messages")
                    }
                    ForEach(rows) { item in
                        ChatEventRow(
                            item: item,
                            defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                            agentLabel: { backend in
                                model.backend(for: backend)?.label ?? backend.capitalized
                            },
                            attachmentData: attachmentData(for: item),
                            isPending: pendingApproval(item),
                            resolve: { approval, choice in
                                Task { await model.resolve(approval, choice: choice) }
                            },
                            attachmentIsLoading: model.loadingResponseAttachments.contains(attachmentID(for: item)),
                            attachmentError: model.responseAttachmentErrors[attachmentID(for: item)],
                            downloadAttachment: { attachment in
                                Task { await model.downloadResponseAttachment(attachment) }
                            },
                            faceSeed: model.faceSeed,
                            isLive: model.busy && item.id == model.displayItems.last?.id,
                            animatesRunning: item.id == spinning
                        )
                        .equatable()
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
                            watched: !follow.scrolling
                                && ((model.hasEarlier && measuringRows) || !follow.atEnd)
                        )
                    }
                    if sliceOffset == 0 {
                        if let mood = liveMood {
                            ChatWorkingIndicator(seed: model.faceSeed, mood: mood)
                        }
                        TranscriptBottomSentinel()
                    }
                }
                // One gate for the whole stack, not one per row: hit testing
                // sleeps mid-fling so sliding rows under a stationary pointer
                // fire no hover enter/exit traffic, and wakes 0.35s after the
                // last moved frame. The pill rides outside this stack and
                // never loses taps.
                .allowsHitTesting(!follow.scrolling)
                .frame(maxWidth: ReadingRoom.laneWidth, alignment: .leading)
                .padding(.vertical, Theme.Space.xl)
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .top)
                .chatScrollContent()
            }
            // Cover the build-up, do not hide the stack. Opacity 0 is how a
            // lazy stack skipped measuring the last prompt: those rows were
            // not visible, so they stayed at estimated height until a click
            // forced a real layout.
            .overlay {
                if !transcriptReady {
                    TranscriptSkeleton()
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: transcriptReady)
            .chatScrollMetrics { metrics in
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
            .overlay(alignment: .bottom) {
                if model.approvals.isEmpty {
                    TranscriptFollowPill(
                        showJump: follow.showJump,
                        busy: model.busy,
                        paused: follow.paused,
                        resume: {
                            showNewest()
                            follow.jump()
                            Task { await returnToLatest(proxy) }
                        },
                        pause: { follow.pause() }
                    )
                }
            }
            .transcriptEarlierPages(model, window: window, proxy: proxy)
            .onChange(of: structureToken) { _, _ in
                // Tool-heavy (Codex) turns change shape per poll. An animated
                // pin per poll is what yanked scrollback, so structural pins
                // are silent while busy and skipped entirely when at the end
                // (growth frames repin on their own).
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: followPulse) { _, _ in
                showNewest()
                follow.jump()
                Task { await returnToLatest(proxy) }
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
                follow.active = active
                // This pane stays mounted behind other destinations. Coming
                // forward has to put the end back under the viewport: a
                // hidden layout pass leaves the last prompt off-screen, and
                // the settle task is keyed on the conversation, so it will
                // not run again.
                if active, follow.pinned, follow.arrived, !follow.settling {
                    Task { await chaseLatest(proxy) }
                }
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
            .onChange(of: model.displayItems.count, initial: true) { _, _ in
                follow.sliceHidesNewest = sliceOffset > 0
                #if DEBUG
                TranscriptProbe.shared.rows = model.displayItems.count
                TranscriptProbe.shared.built = visibleItems.count
                #endif
            }
            #if DEBUG
            .onAppear {
                TranscriptProbe.shared.install()
                TranscriptProbe.shared.rows = model.displayItems.count
                TranscriptProbe.shared.built = visibleItems.count
            }
            #endif
            .onAppear {
                follow.suppressed = !model.approvals.isEmpty
                window.nearTopChanged = { measuringRows = $0 }
                installRepin(proxy)
                pinToLatest(proxy, animated: false)
            }
            .task(id: model.readingIdentity) {
                // A lazy stack does not know its own height until it has drawn
                // the rows, so the first scroll to the end lands on estimates.
                // Hold the end across the frames it takes the real heights to
                // arrive: the intermediate ones all say the end is far below,
                // and believing one of them is how a long conversation used to
                // open in its middle.
                //
                // Only while in front. This pane stays mounted behind other
                // destinations, and scrolling a zero-size proxy to estimated
                // heights is how it came back painted off-origin.
                guard isActive else { return }
                if await restoreReadingPlace(proxy) != .unavailable { return }
                guard !Task.isCancelled else { return }
                showNewest()
                follow.settle(true)
                defer { follow.settle(false) }
                // Hold the end until the conversation has stopped arriving,
                // and then for a few frames while the last rows measure
                // themselves. A fixed count was a guess at how long the
                // opening backfill takes, and the pages that landed after it
                // ran out are what left the view in the middle.
                var quiet = 0
                var correctionPins = 0
                for _ in 0..<Self.settleFrames {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, isActive, model.approvals.isEmpty else { return }
                    // A lazy-stack scroll walks every row between here and
                    // the end. Limit settling corrections; geometry-based
                    // repinning handles later height changes.
                    if !follow.atEnd, correctionPins < 3 {
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

    /// Whether the transcript may be looked at.
    ///
    /// Both halves, because they cover different frames. `openingConversation`
    /// is true from the instant a conversation is picked, before the settle
    /// task has run, which is the second of half-built rows that used to show
    /// before the wireframe replaced them. `arrived` covers the rest, until
    /// the end is under the viewport and steady.
    private var transcriptReady: Bool {
        follow.arrived && !model.openingConversation
    }

    /// The longest the opening pin holds, in fifty-millisecond frames. It
    /// stops once the conversation has arrived and the end has been steady
    /// for a moment, so this is the ceiling on a slow host and not what an
    /// open costs.
    private static let settleFrames = 40

    /// Rows the transcript builds this pass. A fixed-width slice, never a
    /// growing suffix: appending below the viewport shifts nothing, earlier
    /// pages arrive through the paging path, older built rows by sliding.
    private var visibleItems: [ChatDisplayItem] {
        TranscriptSlice.items(model.displayItems, olderOffset: sliceOffset)
    }

    /// Rows above the built slice. Zero while the whole conversation fits.
    private var hiddenAboveCount: Int {
        TranscriptSlice.hiddenAbove(count: model.displayItems.count, olderOffset: sliceOffset)
    }

    /// `olderOffset` counted from the live end, or the offset that still
    /// starts on `sliceAnchor` after rows arrived above or below.
    private var sliceOffset: Int {
        if olderOffset > 0, let anchor = sliceAnchor {
            return TranscriptSlice.holding(anchor, in: model.displayItems, current: olderOffset)
        }
        return TranscriptSlice.clampOffset(olderOffset, count: model.displayItems.count)
    }

    private func showNewest() {
        applySlice(0)
    }

    private func revealEarlier() {
        follow.stopFollowing()
        applySlice(
            TranscriptSlice.revealingEarlier(
                count: model.displayItems.count, olderOffset: sliceOffset
            )
        )
    }

    /// Slide the built window and remember its first row so later inserts
    /// cannot replace what is on screen.
    private func applySlice(_ offset: Int) {
        let clamped = TranscriptSlice.clampOffset(offset, count: model.displayItems.count)
        olderOffset = clamped
        if clamped > 0 {
            sliceAnchor = TranscriptSlice.items(
                model.displayItems, olderOffset: clamped
            ).first?.id
            follow.sliceHidesNewest = true
        } else {
            sliceAnchor = nil
            follow.sliceHidesNewest = false
        }
    }


    /// Come back to the latest turn, by the cheapest route that works.
    ///
    /// The ForEach is a bounded slice, so scrolling it is cheap. Reopening
    /// still drops a host window grown by paging back, which is the memory
    /// and the event list, not the walk.
    private func returnToLatest(_ proxy: ScrollViewProxy) async {
        showNewest()
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

    /// Let the scroll callback put the viewport back on the end.
    ///
    /// Weak, because the state owns the closure and the closure would
    /// otherwise own the state. The proxy and the model are both fine to hold:
    /// neither is owned by what is holding this.
    private func installRepin(_ proxy: ScrollViewProxy) {
        let state = follow
        let model = model
        state.repin = { [weak state] in
            guard let state, state.active, state.pinned, !state.sliceHidesNewest,
                  model.approvals.isEmpty else { return false }
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
        Menu(model.selected?.title ?? "Chat") {
            ForEach(model.chats) { conversation in
                Button(conversation.title) { Task { await model.select(conversation) } }
            }
        }
    }
    #endif

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

    /// Whether a scroll to the end is the actual latest turn.
    ///
    /// The ForEach is a bounded slice, so walking it is cheap. A slice that
    /// has dropped the newest rows is not the end, and pinning it would pin
    /// a sentinel under old messages.
    private var canScrollToEnd: Bool { sliceOffset == 0 }

    private func pinToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // A pending request owns the view. Streaming text must not scroll it
        // back out from under somebody who is reading it to decide.
        // And a hidden pane owns no viewport: this view stays mounted behind
        // other destinations, and scrolling its zero-size proxy is what left
        // it painted off-origin until a resize.
        guard isActive, follow.pinned, model.approvals.isEmpty else { return }
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
            applySlice(TranscriptSlice.revealing(id, in: model.displayItems))
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

    /// Open this conversation where it was left, when it was left above the
    /// latest turn. Navigation or scrolling interrupts restoration.
    private func restoreReadingPlace(_ proxy: ScrollViewProxy) async -> TranscriptReading.Restoration {
        guard let reference = model.currentReference,
              let mark = ChatReadingStore.shared.mark(for: reference) else { return .unavailable }
        return await TranscriptReading.restore(mark, reference: reference, model: model, follow: follow) { id, point in
            placeRow(id, proxy, at: point)
        }
    }

    /// Put one row where the reader had it, with the rest of the conversation
    /// below it and the earlier part one button above.
    private func placeRow(_ id: String, _ proxy: ScrollViewProxy, at point: UnitPoint) {
        guard isActive else { return }
        applySlice(TranscriptSlice.holding(id, in: model.displayItems, current: 0))
        follow.markDrivenInstant()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: point)
        }
    }

    private func pendingApproval(_ item: ChatDisplayItem) -> Bool {
        if case let .approval(approval) = item.kind {
            return model.approvals.contains { $0.id == approval.id }
        }
        return false
    }

    private func submit(from chat: ChatConversation, sendNow: Bool = false) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attached image is content on its own: text is only mandatory
        // when there is nothing attached.
        guard !text.isEmpty || !model.attachments.isEmpty, !model.sending else { return }
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
            Task { await model.sendNow(item) }
            return
        }
        if model.busy {
            guard model.enqueue(text) != nil else { return }
            model.clearDraft()
            showNewest()
            follow.jump()
            followPulse += 1
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

    private var dropExperienceVisible: Bool {
        paneDropTargeted || composerDropTargeted
    }

    private var dropExperience: some View {
        ChatDropExperience()
    }

    private func receive(_ providers: [NSItemProvider]) async {
        await receive(ChatInbox.drops(from: providers))
    }

    private func receive(_ drops: [ChatInboxDrop]) async {
        guard !drops.isEmpty else { return }
        if model.selected == nil {
            await model.create()
        }
        for drop in drops {
            switch drop {
            case let .attachment(item):
                await model.attach(item)
            case let .text(text):
                insertInDraft(text)
            case .folder:
                showDropNotice("Attach files, not folders")
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

    private var emptyConversation: some View {
        VStack(spacing: Theme.Space.m) {
            ChatScene(seed: model.defaultFaceSeed)
            Text("Ask about \(workspaceName ?? "this folder")")
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
            Text("Start a chat")
                .font(Theme.title2.weight(.semibold))
            Text("Ask an agent to explore, plan, or work in this folder.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("New chat", .create) {
                Task { await model.create() }
            }
            .buttonStyle(AccentButtonStyle())
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
        case .tool, .edit, .attachment, .approval, .handoff, .turnSeparator, .usage:
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
        case .tool, .edit, .attachment, .approval, .handoff, .turnSeparator, .usage:
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
                Text("Drop to attach")
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("Files attach. Text and links join your message.")
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
