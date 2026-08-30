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

    @State private var model = ChatModel()
    @State private var loaded = false
    @State private var created: ChatConversation?
    @State private var pendingDelete: ChatConversation?

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
    @State private var showingSetup = false
    @State private var showingPersonas = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chat: ChatConversation? {
        model.chats.first { $0.id == chatID } ?? model.selected
    }

    var body: some View {
        VStack(spacing: 0) {
            if let chat {
                transcript(chat)
                ClientChatComposer(
                    draft: $draft,
                    attachments: model.attachments,
                    previews: model.attachmentPreviews,
                    running: chat.running,
                    placeholder: "Ask about \(folderName.isEmpty ? "this folder" : folderName)",
                    onSend: { submit(from: chat) },
                    onStop: { Task { await model.stop() } },
                    onAttach: { item in await model.attach(item) },
                    onRemove: { model.removeAttachment($0) }
                )
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
                    ChatSetupHeader(
                        model: model,
                        chat: chat,
                        collapsed: model.hasStarted,
                        onOpenInspector: { showingSetup = true }
                    )
                    ForEach(model.displayItems) { item in
                        ClientChatEventRow(
                            item: item,
                            isPending: pendingApproval(item),
                            resolve: { approval, choice in
                                Task { await model.resolve(approval, choice: choice) }
                            }
                        )
                    }
                    if chat.running {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Working")
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                        }
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
            .onAppear { scrollToLatest(proxy) }
        }
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
        case let .assistant(text), let .thinking(text):
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
        if reduceMotion {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func submit(from chat: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.running else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

#endif
