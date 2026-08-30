// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel
    let workspaceID: String
    var workspaceName: String? = nil
    var onOpenInspector: (() -> Void)? = nil
    @State private var draft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar(scope: workspaceName.map { ScopeChip(label: $0, symbol: "folder.fill") }) {
                conversationMenu
                ToolbarIconButton(systemImage: "plus", help: "New chat") {
                    Task { await model.create() }
                }
            }
            #endif
            if let chat = model.selected {
                transcript(chat)
                ChatComposer(
                    draft: $draft,
                    attachments: model.attachments,
                    previews: model.attachmentPreviews,
                    running: chat.running,
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

    private var conversationMenu: some View {
        Menu {
            if model.chats.isEmpty {
                Text("No chats yet")
            } else {
                ForEach(model.chats) { chat in
                    Button(chat.running ? "\(chat.title) · working" : chat.title, .comment) {
                        Task { await model.select(chat) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if model.selected?.running == true {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 7, height: 7)
                }
                Text(model.selected?.title ?? "Chat")
                    .font(Theme.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(model.chats.isEmpty)
        .frame(maxWidth: 260, alignment: .leading)
        .help("Switch conversation")
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
                    ChatSetupHeader(
                        model: model,
                        chat: chat,
                        collapsed: model.hasStarted,
                        onOpenInspector: onOpenInspector
                    )
                    ForEach(model.displayItems) { item in
                        ChatEventRow(
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
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.Space.l)
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

    private func submit(from chat: ChatConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.running else { return }
        draft = ""
        Task { await model.send(text) }
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
