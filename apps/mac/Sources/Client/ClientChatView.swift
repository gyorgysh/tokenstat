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
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase

    private var place: String { folderName.isEmpty ? "this folder" : folderName }

    var body: some View {
        Group {
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
        // The floating tab bar sits under the composer. SwiftUI's toolbar
        // hide only minimises it on iOS 26. Bound here so Back to the list
        // is an update on the same prober, not a teardown after this view
        // has left the window.
        .clientTabBarHidden(opened != nil)
        .onChange(of: opened?.id, initial: true) { _, id in
            navigation.visibleChatID = id
        }
        .onDisappear {
            // Locking the phone must not forget this thread. A tap on its
            // notification would otherwise remount it over itself.
            guard scenePhase == .active,
                  UIApplication.shared.applicationState == .active
            else { return }
            if let id = opened?.id, navigation.visibleChatID == id {
                navigation.visibleChatID = nil
            }
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
            if await openRequestedChat() { return }
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
        .onChange(of: navigation.openChatID) { _, _ in
            Task { await openRequestedChat() }
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
        // A tap that arrived mid-reload found an empty list and returned
        // without consuming. Retry now that the folder has answered.
        await openRequestedChat()
    }

    private func create() async {
        await model.create()
        opened = model.selected
    }

    /// A notification named this conversation. Only consume it if it is in
    /// this folder, so a list that is still on screen for another workspace
    /// cannot steal the tap. Already open is a no-op: re-selecting blanks
    /// the transcript.
    @discardableResult
    private func openRequestedChat() async -> Bool {
        guard let id = navigation.openChatID, !id.isEmpty else { return false }
        if opened?.id == id {
            navigation.openChatID = nil
            return true
        }
        guard let chat = model.chats.first(where: { $0.id == id }) else { return false }
        await model.select(chat)
        opened = chat
        navigation.openChatID = nil
        return true
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
    @State private var showingSetup = false
    @State private var showingPersonas = false
    @State private var urlDropTargeted = false
    @State private var textDropTargeted = false
    @State private var dataDropTargeted = false
    @State private var composerDropTargeted = false
    @State private var dropNotice: String?
    @State private var dropNoticeGeneration = 0
    @State private var previewFile: ChatPreviewedFile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var chat: ChatConversation? {
        model.chats.first { $0.id == chatID } ?? model.selected
    }

    var body: some View {
        VStack(spacing: 0) {
            if let chat {
                // The bar is pinned, not the next row of a stack. Stacked,
                // it had the window background under it rather than the
                // conversation, so its glass had nothing to be glass about and
                // read as a white slab whatever material it asked for. As a
                // bottom bar the transcript runs underneath, including the
                // home indicator, which is the whole point of the material.
                transcript(chat)
                    .overlay {
                        if dropExperienceVisible {
                            ChatDropExperience(seed: model.faceSeed)
                        }
                    }
                    .clientBottomBar {
                        bar(chat)
                            .padding(.top, Theme.Space.s)
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
        .task(id: "\(chatID)-\(scenePhase == .active)") {
            // Backgrounded chats stop polling. Every mounted conversation
            // otherwise polls every 2s indefinitely, churning the view graph
            // for a screen nobody sees.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: model.pollInterval)
                guard !Task.isCancelled else { return }
                await model.poll()
            }
        }
        // What is on screen, for the local notifier. Without this,
        // `isWatching()` is always false on iOS and on-device banners are
        // never suppressed (host push suppression still works via heartbeat).
        .onChange(of: chatID, initial: true) { _, id in
            UserPresence.shared.chatSurface(showing: id.isEmpty ? nil : id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatAttachmentCachePurged)) { _ in
            model.clearCachedAttachmentMemory()
        }
        // Presented here rather than on the row. A row lives in a lazy stack
        // that is free to tear it down while it is being tapped, and a
        // presentation that goes with it is a tap that does nothing.
        .fullScreenCover(item: $previewFile) { file in
            ClientFilePreview(file: file) { previewFile = nil }
                .ignoresSafeArea()
        }
        .onDisappear {
            UserPresence.shared.chatSurface(showing: nil)
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

    /// Same rule as the Mac: a blocked turn takes the composer's place. On a
    /// phone this matters more, not less, because the card scrolls out of a
    /// short viewport in one streamed paragraph.
    @ViewBuilder
    private func bar(_ chat: ChatConversation) -> some View {
        if model.approvals.isEmpty {
            VStack(spacing: Theme.Space.s) {
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
                        }
                    )
                    .padding(.horizontal, Theme.Space.s)
                }
                ClientChatComposer(
                    model: model,
                    chat: chat,
                    draft: $draft,
                    attachments: model.attachments,
                    previews: model.attachmentPreviews,
                    running: model.busy,
                    placeholder: model.busy
                        ? "Send after this turn"
                        : "Ask about \(folderName.isEmpty ? "this folder" : folderName)",
                    onSend: { submit(from: chat) },
                    onSendNow: { submit(from: chat, sendNow: true) },
                    onStop: { Task { await model.stop() } },
                    onKeyboardDidHide: {
                        guard follow.pinned else { return }
                        followPulse += 1
                    },
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
            }
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
                        Button("Show \(hiddenAboveCount) earlier messages", .history) {
                            revealEarlier()
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Show earlier messages")
                    }
                    ForEach(rows) { item in
                        ClientChatEventRow(
                            item: item,
                            attachmentData: attachmentData(for: item),
                            defaultAgentName: model.backend(for: chat.backend)?.label ?? chat.backend.capitalized,
                            agentLabel: { backend in
                                model.backend(for: backend)?.label ?? backend.capitalized
                            },
                            isPending: pendingApproval(item),
                            resolve: { approval, choice in
                                Task { await model.resolve(approval, choice: choice) }
                            },
                            attachmentIsLoading: model.loadingResponseAttachments.contains(attachmentID(for: item)),
                            attachmentError: model.responseAttachmentErrors[attachmentID(for: item)],
                            downloadAttachment: { attachment in
                                Task { await model.downloadResponseAttachment(attachment) }
                            },
                            openAttachment: open(_:data:),
                            faceSeed: model.faceSeed,
                            isLive: model.busy && item.id == model.displayItems.last?.id,
                            animatesRunning: item.id == spinning
                        )
                        .equatable()
                        // No geometry readers mid-fling: each one reports per
                        // frame, and a fast scroll turns those reports into a
                        // transaction per frame that placement never drains.
                        // Readers return 0.35s after the last moved frame, via
                        // `scrolling`, before any paging decision needs them.
                        .transcriptRowFrame(item.id, watched: model.hasEarlier && measuringRows && !follow.scrolling)
                    }
                    if sliceOffset == 0 {
                        if let mood = liveMood {
                            ChatWorkingIndicator(seed: model.faceSeed, mood: mood)
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
                .allowsHitTesting(!follow.scrolling)
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)
                .chatScrollContent()
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
                if !transcriptReady {
                    TranscriptSkeleton()
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
                if !follow.atEnd { pinToLatest(proxy, animated: !model.busy) }
            }
            .onChange(of: followPulse) { _, _ in
                showNewest()
                follow.jump()
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
            .task(id: model.selected?.id) {
                // A lazy stack does not know its own height until it has drawn
                // the rows, so the first scroll to the end lands on estimates.
                // Hold the end across the frames the real heights take to
                // arrive: every one of those says the end is far below, and
                // believing one is how a long chat opened in its middle.
                showNewest()
                follow.settle(true)
                defer { follow.settle(false) }
                // Same as the Mac: hold the end until the conversation has
                // stopped arriving, not for a fixed count of frames.
                var quiet = 0
                var correctionPins = 0
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, model.approvals.isEmpty else { return }
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
            showDropNotice("\(attachment.name) could not be opened. \(error.localizedDescription)")
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

    /// Rows the transcript builds this pass. Same slice as the Mac.
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

    /// Let the scroll callback put the viewport back on the end. Weak on the
    /// state, which owns the closure.
    private func installRepin(_ proxy: ScrollViewProxy) {
        let state = follow
        let model = model
        state.repin = { [weak state] in
            guard let state, state.pinned, !state.sliceHidesNewest,
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
        guard follow.pinned, model.approvals.isEmpty else { return }
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
        // Instant pins land on the same frame and only need a short window.
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

    private func submit(from chat: ChatConversation, sendNow: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attached image is content on its own: text is only mandatory
        // when there is nothing attached.
        guard !text.isEmpty || !model.attachments.isEmpty, !model.sending else { return }
        // Enqueue first: a full queue reports an error and returns nil, and
        // the words must survive that path rather than being wiped.
        if sendNow {
            guard let item = model.enqueue(text, atFront: true) else { return }
            draft = ""
            // Sending is engaging: follow is the default, so a new turn resumes
            // it even if it was paused before. Pausing again is one tap. Hide the
            // keyboard and snap to the end so the next tokens are not off-screen
            // above a closed keyboard.
            showNewest()
            follow.jump()
            followPulse += 1
            Task { await model.sendNow(item) }
            return
        }
        if model.busy {
            guard model.enqueue(text) != nil else { return }
            draft = ""
            showNewest()
            follow.jump()
            followPulse += 1
            return
        }
        draft = ""
        showNewest()
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
