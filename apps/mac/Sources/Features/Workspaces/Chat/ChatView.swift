// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel
    let workspaceID: String
    var workspaceName: String? = nil
    @State private var draft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar(scope: workspaceName.map { ScopeChip(label: $0, symbol: "folder.fill") }) {
                ToolbarIconButton(systemImage: "plus", help: "New chat") {
                    Task { await model.create() }
                }
            }
            #endif
            if let chat = model.selected {
                transcript(chat)
                ChatComposer(
                    model: model,
                    chat: chat,
                    draft: $draft,
                    attachments: model.attachments,
                    previews: model.attachmentPreviews,
                    running: model.busy,
                    placeholder: "Ask about \(workspaceName ?? "this folder")",
                    onSend: { submit(from: chat) },
                    onStop: { Task { await model.stop() } },
                    onAttach: { item in await model.attach(item) },
                    onRemove: { model.removeAttachment($0) }
                )
            } else {
                empty
            }
        }
        .background(Theme.background)
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
        .task(id: workspaceID) { await model.load(workspaceID: workspaceID) }
        .task(id: model.selected?.id) {
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
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    #if !os(macOS)
                    if !model.chats.isEmpty {
                        conversationMenu
                    }
                    #endif
                    if model.displayItems.isEmpty, !chat.running {
                        emptyConversation
                    }
                    ForEach(model.displayItems) { item in
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
                            }
                        )
                    }
                    if model.busy {
                        ChatWorkingIndicator()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.vertical, Theme.Space.xl)
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: scrollToken) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: chat.running) { _, _ in
                scrollToLatest(proxy)
            }
            .onAppear { scrollToLatest(proxy) }
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

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        let animated = !reduceMotion
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    /// Count alone misses streaming: coalesced text grows in place.
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

    private func submit(from chat: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busy else { return }
        draft = ""
        Task { await model.send(text) }
    }

    private var emptyConversation: some View {
        VStack(spacing: Theme.Space.m) {
            ChatScene(reduceMotion: reduceMotion)
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
            ChatScene(reduceMotion: reduceMotion)
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
