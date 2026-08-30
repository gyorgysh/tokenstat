// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Conversation settings, the folder it runs in, the allowlist, and cost.
///
/// After the first turn the setup header collapses, so this pane is where
/// those controls live for the rest of the conversation.
struct ChatInspector: View {
    @Bindable var model: ChatModel
    var folder: WorkspaceFolder?
    var onClose: () -> Void
    @State private var showingPersonas = false
    @State private var pendingDelete = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                chromeMark
                    .padding(.leading, Theme.Space.m)
                Text("Chat")
                    .font(Theme.font(13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Group {
                if let chat = model.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            identity(chat)
                            ChatSetupHeader(model: model, chat: chat, collapsed: false, showsIntro: false)
                            folderCard
                            allowlist(chat)
                            if let usage = model.turnUsage {
                                costCard(usage)
                            }
                            Button("Delete chat", .delete, role: .destructive) {
                                pendingDelete = true
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { titleDraft = chat.title }
                    .onChange(of: chat.id) { _, _ in titleDraft = chat.title }
                    .onChange(of: chat.title) { _, next in
                        if !titleFocused, titleDraft != next { titleDraft = next }
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle(chat) }
                    }
                } else {
                    InspectorEmptyState(
                        systemImage: "bubble.left.and.bubble.right",
                        title: "Start a chat",
                        subtitle: "A conversation's settings, allowlist and cost open here.",
                        tint: Theme.accent
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .sheet(isPresented: $showingPersonas) {
            PersonaEditor(model: model, onClose: { showingPersonas = false })
                .presentationBackground(Theme.background)
        }
        .confirmationDialog("Delete this chat?", isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("Delete chat", role: .destructive) {
                if let chat = model.selected {
                    Task { await model.remove(chat) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript stays on this computer until you delete it. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var chromeMark: some View {
        if let chat = model.selected {
            HarnessMark(id: chat.backend, size: 16)
        } else {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16, height: 16)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
    }

    private func identity(_ chat: ChatConversation) -> some View {
        group("Conversation") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Title", text: $titleDraft)
                    .themedFieldBox()
                    .focused($titleFocused)
                    .onSubmit { commitTitle(chat) }
                HStack(spacing: Theme.Space.s) {
                    Button("Personas", .persona) { showingPersonas = true }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    if chat.running {
                        Text("Working")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var folderCard: some View {
        group("Folder") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(folder?.name ?? "This workspace")
                    .font(Theme.callout.weight(.medium))
                if let path = folder?.path, !path.isEmpty {
                    Text(path)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func allowlist(_ chat: ChatConversation) -> some View {
        group("Always allowed") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Always allow on a permission card writes here. Remove a rule to ask again.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if chat.allowedTools.isEmpty && chat.allowedShellPrefixes.isEmpty {
                    Text("Nothing is remembered yet.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(chat.allowedTools, id: \.self) { tool in
                            allowChip(tool) {
                                Task {
                                    await model.update(
                                        allowedTools: chat.allowedTools.filter { $0 != tool }
                                    )
                                }
                            }
                        }
                        ForEach(chat.allowedShellPrefixes, id: \.self) { prefix in
                            allowChip(prefix) {
                                Task {
                                    await model.update(
                                        allowedShellPrefixes: chat.allowedShellPrefixes.filter { $0 != prefix }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func allowChip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
            Button("Remove", .dismiss) { remove() }
                .buttonStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.accentSoft, in: Capsule())
    }

    private func costCard(_ usage: (input: UInt64, output: UInt64, cost: Double)) -> some View {
        group("This conversation") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("\(usage.input.formatted()) in · \(usage.output.formatted()) out")
                    .font(Theme.callout)
                if usage.cost > 0 {
                    Text(usage.cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private func commitTitle(_ chat: ChatConversation) {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != chat.title else {
            if title.isEmpty { titleDraft = chat.title }
            return
        }
        Task { await model.update(title: title) }
    }
}
