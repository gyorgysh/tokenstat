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
    @State private var created: ChatConversation?
    @State private var pendingDelete: ChatConversation?
    /// The launcher may skip the list once. Back from the thread must still
    /// reach the list rather than immediately pushing the same chat again.
    @State private var didOpenConversation = false

    private var place: String { folderName.isEmpty ? "this folder" : folderName }

    var body: some View {
        ClientCardList(
            title: "Chat",
            errorMessage: model.error.map { ClientTunnelCopy.display($0, host: hostName) },
            isLoaded: loaded,
            isEmpty: model.chats.isEmpty,
            emptyText: "Start a chat",
            emptyArt: .chat,
            emptyMessage: "Ask an agent to explore, plan, or work in \(place).",
            emptyActionTitle: "New chat",
            emptyActionIcon: .create,
            emptyAction: { Task { await create() } },
            refreshKey: "workspace-chat-\(workspaceID)",
            reload: { await reload() }
        ) {
            ForEach(model.chats) { chat in
                NavigationLink {
                    ClientChatThread(
                        model: model,
                        chatID: chat.id,
                        folderName: folderName,
                        hostName: hostName
                    )
                } label: {
                    row(chat)
                }
                .navigationLinkIndicatorVisibility(.hidden)
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
        .navigationDestination(item: $created) { chat in
            ClientChatThread(
                model: model,
                chatID: chat.id,
                folderName: folderName,
                hostName: hostName
            )
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
                    created = recent
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
        created = model.selected
    }
}

/// One conversation: setup, transcript, glass composer.
private struct ClientChatThread: View {
    @Bindable var model: ChatModel
    let chatID: String
    let folderName: String
    let hostName: String
    @State private var draft = ""
    /// A row the transcript should jump to, set by the pending-approval bar.
    @State private var scrollTarget: String?
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
                    art: .chat
                )
                .padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
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
                .presentationBackground(Theme.background)
        }
        .task {
            if let chat = model.chats.first(where: { $0.id == chatID }) {
                await model.select(chat)
            }
        }
        .task(id: chatID) {
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
            Text(model.error.map { ClientTunnelCopy.display($0, host: hostName) } ?? "")
        }
    }

    private func transcript(_ chat: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
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
                            }
                        )
                    }
                    if model.busy {
                        ChatWorkingIndicator(
                            seed: model.faceSeed,
                            isRunningTool: model.isRunningTool
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .clientHideScrollEdgeEffect()
            .onChange(of: scrollToken) { _, _ in scrollToLatest(proxy) }
            .onChange(of: chat.running) { _, _ in scrollToLatest(proxy) }
            // A request that arrives mid-stream would otherwise be pushed off
            // a short viewport before anybody saw it.
            .onChange(of: model.approvals.first?.id) { _, id in
                guard let id else { return }
                scrollTo("approval-\(id)", proxy)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                scrollTo(target, proxy)
                scrollTarget = nil
            }
            .onAppear { scrollToLatest(proxy) }
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

    private var scrollToken: String {
        guard let last = model.displayItems.last else { return "" }
        switch last.kind {
        case let .assistant(text, _), let .thinking(text):
            return "\(last.id)-\(text.count)"
        case let .tool(state):
            return "\(last.id)-\(state.running)-\(state.failed)-\(state.detail?.count ?? 0)"
        default:
            return last.id
        }
    }

    private func pendingApproval(_ item: ChatDisplayItem) -> Bool {
        if case let .approval(approval) = item.kind {
            return model.approvals.contains { $0.id == approval.id }
        }
        return false
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        // A pending request owns the view. Streaming text must not scroll it
        // out from under somebody who is reading it to decide.
        guard model.approvals.isEmpty else { return }
        scrollTo("chat-bottom", proxy)
    }

    private func scrollTo(_ id: String, _ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func submit(from chat: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busy else { return }
        draft = ""
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
