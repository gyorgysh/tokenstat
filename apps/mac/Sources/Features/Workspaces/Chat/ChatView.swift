// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var model: ChatModel
    let workspaceID: String
    var workspaceName: String? = nil
    var onOpenInspector: (() -> Void)? = nil
    @State private var draft = ""
    @State private var importingAttachment = false
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
                composer(chat)
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
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
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
                    ForEach(model.events) { row in
                        ChatEventRow(
                            row: row,
                            isPending: row.approval.map { approval in
                                model.approvals.contains { $0.id == approval.id }
                            } ?? false,
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
            .onChange(of: model.events.count) { _, _ in
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

    private func composer(_ chat: ChatConversation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !model.attachments.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(model.attachments) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: ActionIcon.attach.symbol)
                                .foregroundStyle(Theme.accent)
                            Text(attachment.name)
                                .font(Theme.caption)
                                .lineLimit(1)
                            Button("Remove", .dismiss) { model.removeAttachment(attachment) }
                                .buttonStyle(.plain)
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.panel, in: Capsule())
                        .overlay { Capsule().strokeBorder(Theme.border, lineWidth: 1) }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                Button("Attach", .attach) { importingAttachment = true }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .environment(\.compactActions, true)
                    .disabled(chat.running)
                TextField("Ask about \(workspaceName ?? "this folder")", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 10)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }
                    #if os(macOS)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) {
                            submit(from: chat)
                            return .handled
                        }
                        return .ignored
                    }
                    #endif
                if chat.running {
                    Button("Stop", .stop) { Task { await model.stop() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .environment(\.compactActions, true)
                } else {
                    Button("Send", .send) { submit(from: chat) }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .environment(\.compactActions, true)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.background)
        .fileImporter(
            isPresented: $importingAttachment,
            allowedContentTypes: [.image, .pdf, .plainText, .sourceCode]
        ) { result in
            if case let .success(file) = result {
                Task { await model.attach(file) }
            }
        }
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

private struct ChatEventRow: View {
    let row: ChatTimelineEvent
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void
    var body: some View {
        if row.kind == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(row.text ?? "")
                    .font(Theme.body)
                    .padding(Theme.Space.m)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else if let approval = row.approval {
            ChatApprovalCard(approval: approval, isPending: isPending, resolve: resolve)
        } else if let event = row.event {
            switch event.kind {
            case "text":
                Text(event.delta ?? "")
                    .font(Theme.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case "thinking":
                Label(event.delta ?? "Thinking", systemImage: "brain")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            case "toolStart":
                Label(
                    [event.verb, event.target].compactMap { $0 }.joined(separator: " "),
                    systemImage: "hammer"
                )
                .font(Theme.callout)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            case "edit":
                Label(
                    "\(event.path ?? "File")  +\(event.added ?? 0)  −\(event.removed ?? 0)",
                    systemImage: "pencil.line"
                )
                .font(Theme.callout)
                .foregroundStyle(Theme.accent)
            case "failed":
                Label(event.text ?? "The turn failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            case "usage":
                Text("\(event.input ?? 0) in · \(event.output ?? 0) out")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}

/// A decision stays where the agent stopped, so the person can see the tool,
/// its target and the surrounding response without losing their reading place.
private struct ChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.accent)
                Text(isPending ? "Permission needed" : "Permission answered")
                    .font(Theme.callout.weight(.semibold))
                Spacer()
                Text(approval.verb)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentSoft, in: Capsule())
            }
            Text(approval.preview)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .lineLimit(4)
            if isPending {
                HStack(spacing: Theme.Space.s) {
                    Button("Allow", .allow) { resolve(approval, "allow") }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Button("Always allow", .allow) { resolve(approval, "allowAlways") }
                        .buttonStyle(AccentButtonStyle(small: true))
                    Button("Deny", .deny, role: .destructive) { resolve(approval, "deny") }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            } else {
                Label("This request is no longer waiting.", systemImage: "checkmark.circle")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isPending ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        }
    }
}
