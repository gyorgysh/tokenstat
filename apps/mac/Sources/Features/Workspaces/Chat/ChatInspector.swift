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
    var showsHeader = true
    @State private var showingPersonas = false
    @State private var pendingDelete = false
    @State private var deletionTarget: DeletionTarget?

    private struct DeletionTarget {
        let chat: ChatConversation
        let owner: WorkReference
    }
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: L10n.text("apple.chatinspector.chat.460b3a7d"), symbol: "bubble.left.and.bubble.right")
                Spacer(minLength: 0)
            }
            }
            Group {
                if let chat = model.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            identity(chat)
                            ChatSetupHeader(model: model, chat: chat, collapsed: false, showsIntro: false)
                            ChatInstructionsCard(model: model, chat: chat)
                            folderCard
                            allowlist(chat)
                            ChatCostMeter(totals: model.turnUsage)
                            Button(L10n.text("apple.chatinspector.delete_chat.93291d9c"), .delete, role: .destructive) {
                                guard let owner = model.currentReference else { return }
                                deletionTarget = DeletionTarget(chat: chat, owner: owner)
                                pendingDelete = true
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.currentReference == nil || model.savedCopy != nil)
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
                        title: L10n.text("apple.chatinspector.start_a_chat.d80b1888"),
                        subtitle: L10n.text("apple.chatinspector.a_conversation_s_settings_allowlist_and_co.c2f31ecf"),
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
        }
        .confirmationDialog(L10n.text("apple.chatinspector.delete_this_chat.848dad9b"), isPresented: $pendingDelete, titleVisibility: .visible) {
            Button(L10n.text("apple.chatinspector.delete_chat.93291d9c"), role: .destructive) {
                guard let target = deletionTarget else { return }
                Task {
                    guard model.currentReference == target.owner,
                          model.selected?.id == target.chat.id,
                          model.savedCopy == nil else { return }
                    await model.remove(target.chat)
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.chatinspector.the_transcript_stays_on_this_computer_unti.46662c93"))
        }
        .onChange(of: model.currentReference) { _, _ in
            pendingDelete = false
            deletionTarget = nil
        }
        .onChange(of: model.savedCopy != nil) { _, saved in
            if saved {
                pendingDelete = false
                deletionTarget = nil
            }
        }
    }

    private func identity(_ chat: ChatConversation) -> some View {
        group(L10n.text("apple.chatinspector.conversation.ccca1817")) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField(L10n.text("apple.chatinspector.title.7e8cd205"), text: $titleDraft)
                    .themedFieldBox()
                    .disabled(model.savedCopy != nil)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(chat) }
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("apple.chatinspector.personas.fa2ea3fb"), .persona) { showingPersonas = true }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    if chat.running {
                        Text(L10n.text("common.working"))
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
        group(L10n.text("apple.chatinspector.folder.74ccd433")) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(folder?.name ?? L10n.text("apple.chatinspector.this_project.d0f62545"))
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
        group(L10n.text("apple.chatinspector.always_allowed.94387772")) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.chatinspector.always_allow_on_a_permission_card_writes_h.b50406cc"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if chat.allowedTools.isEmpty && chat.allowedShellPrefixes.isEmpty {
                    Text(L10n.text("apple.chatinspector.nothing_is_remembered_yet.d523b614"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(chat.allowedTools, id: \.self) { tool in
                            allowChip(tool) {
                                change(chat) {
                                    await model.update(
                                        allowedTools: chat.allowedTools.filter { $0 != tool }
                                    )
                                }
                            }
                        }
                        ForEach(chat.allowedShellPrefixes, id: \.self) { prefix in
                            allowChip(prefix) {
                                change(chat) {
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
            Button(L10n.text("common.remove"), .dismiss) { remove() }
                .disabled(model.savedCopy != nil)
                .buttonStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.accentSoft, in: Capsule())
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

    private func change(_ chat: ChatConversation, operation: @escaping @MainActor () async -> Void) {
        let owner = model.currentReference
        Task { @MainActor in
            guard let owner, model.currentReference == owner,
                  model.selected?.id == chat.id, model.savedCopy == nil else { return }
            await operation()
        }
    }

    private func commitTitle(_ chat: ChatConversation) {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != chat.title else {
            if title.isEmpty { titleDraft = chat.title }
            return
        }
        change(chat) { await model.update(title: title) }
    }
}
