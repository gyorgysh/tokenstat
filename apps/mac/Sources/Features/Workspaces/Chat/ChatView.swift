// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

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
    @State private var draft = ""
    @State private var draftSelection = NSRange(location: 0, length: 0)
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
    @State private var paneDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    ChatComposer(
                        model: model,
                        chat: chat,
                        draft: $draft,
                        selection: $draftSelection,
                        attachments: model.attachments,
                        previews: model.attachmentPreviews,
                        running: model.busy,
                        placeholder: "Ask about \(workspaceName ?? "this folder")",
                        onSend: { submit(from: chat) },
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
        .task(id: "\(workspaceID)-\(isActive)") {
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
        .onDisappear {
            UserPresence.shared.chatSurface(showing: nil)
        }
        #endif
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
                try? await Task.sleep(for: .milliseconds(400))
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
        ScrollViewReader { proxy in
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
                    ForEach(model.displayItems) { item in
                        ChatEventRow(
                            item: item,
                            defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                            agentLabel: { backend in
                                model.backend(for: backend)?.label ?? backend.capitalized
                            },
                            attachmentData: attachmentData(for: item),
                            attachmentRevision: model.responseAttachmentRevision,
                            isPending: pendingApproval(item),
                            resolve: { approval, choice in
                                Task { await model.resolve(approval, choice: choice) }
                            },
                            faceSeed: model.faceSeed,
                            isLive: model.busy && item.id == model.displayItems.last?.id
                        )
                        .equatable()
                        #if os(macOS)
                        // Out of hit testing while the viewport moves, and
                        // outside the equatable boundary so the rows themselves
                        // do not rebuild for it. A scroll slides content under
                        // a stationary pointer; every row it crosses would
                        // otherwise enter/exit hover and join the hit-test
                        // walk on each mouse-move event.
                        .allowsHitTesting(!follow.scrolling)
                        #endif
                        .frame(
                            maxWidth: item.prefersWideReadingRoom
                                ? .infinity
                                : ReadingRoom.proseWidth,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, alignment: item.readingRoomAlignment)
                        .transcriptRowFrame(item.id, watched: model.hasEarlier && measuringRows)
                    }
                    if let mood = liveMood {
                        ChatWorkingIndicator(seed: model.faceSeed, mood: mood)
                    }
                    TranscriptBottomSentinel()
                }
                .frame(maxWidth: ReadingRoom.laneWidth, alignment: .leading)
                .padding(.vertical, Theme.Space.xl)
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .top)
                .chatScrollContent()
            }
            // Nobody watches a conversation assemble itself from the top and
            // then jump. It builds behind the wireframe and appears where the
            // reading is.
            .opacity(transcriptReady ? 1 : 0)
            .overlay {
                if !transcriptReady {
                    TranscriptSkeleton()
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .frame(maxWidth: .infinity)
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
                // Tool-heavy (Codex) turns change shape per poll. An animated
                // pin per poll is what yanked scrollback, so structural pins
                // are silent while busy and skipped entirely when at the end
                // (growth frames repin on their own).
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
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
            .onChange(of: isActive, initial: true) { _, active in
                follow.active = active
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
            .onAppear {
                follow.suppressed = !model.approvals.isEmpty
                window.nearTopChanged = { measuringRows = $0 }
                installRepin(proxy)
                pinToLatest(proxy, animated: false)
            }
            .task(id: model.selected?.id) {
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

    /// Let the scroll callback put the viewport back on the end.
    ///
    /// Weak, because the state owns the closure and the closure would
    /// otherwise own the state. The proxy and the model are both fine to hold:
    /// neither is owned by what is holding this.
    private func installRepin(_ proxy: ScrollViewProxy) {
        let state = follow
        let model = model
        state.repin = { [weak state] in
            guard let state, state.active, state.pinned, model.approvals.isEmpty else { return }
            state.markDrivenInstant()
            proxy.scrollTo(TranscriptFollow.bottomID, anchor: .bottom)
        }
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

    private func pinToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // A pending request owns the view. Streaming text must not scroll it
        // back out from under somebody who is reading it to decide.
        // And a hidden pane owns no viewport: this view stays mounted behind
        // other destinations, and scrolling its zero-size proxy is what left
        // it painted off-origin until a resize.
        guard isActive, follow.pinned, model.approvals.isEmpty else { return }
        scrollTo(TranscriptFollow.bottomID, proxy, animated: animated)
    }

    private func scrollTo(_ id: String, _ proxy: ScrollViewProxy, animated: Bool) {
        // Every scroll here is programmatic. Say so, or the frames of the
        // animation read as the reader leaving and unpin mid-flight.
        // Instant pins land on the same frame and only need a short window;
        // the long one is what locked out slow scrollback during streams.
        // Hidden panes do not scroll at all (see pinToLatest).
        guard isActive else { return }
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

    private func pendingApproval(_ item: ChatDisplayItem) -> Bool {
        if case let .approval(approval) = item.kind {
            return model.approvals.contains { $0.id == approval.id }
        }
        return false
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
        paneDropTargeted || composerDropTargeted
    }

    private var dropExperience: some View {
        ChatDropExperience(seed: model.faceSeed)
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
        let current = draft as NSString
        let location = min(max(0, draftSelection.location), current.length)
        let length = min(max(0, draftSelection.length), current.length - location)
        draft = current.replacingCharacters(in: NSRange(location: location, length: length), with: text)
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
    var seed: UInt64

    var body: some View {
        ZStack {
            Theme.accentSoft.opacity(0.58)
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.82), lineWidth: 1.5)
                .padding(8)
            VStack(spacing: Theme.Space.s) {
                PersonaMark(seed: seed, size: 58, state: .waiting)
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
