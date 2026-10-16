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
    @State private var writingAllowlist = false
    @State private var allowlistExpanded = false
    @State private var titleDraft = ""
    @State private var titleOwner: WorkReference?
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
                            ChatContextCard(model: model)
                            ChatActivityCard(model: model)
                            ChatDetailSettings(model: model)
                            ChatSetupHeader(model: model, chat: chat, collapsed: false, showsIntro: false)
                            ChatInstructionsCard(model: model, chat: chat)
                            folderCard
                            allowlist(chat)
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
                        .id(model.currentReference)
                    }
                    .onAppear { resetTitle() }
                    .onChange(of: chat.title) { _, next in
                        if titleOwner == model.currentReference, !titleFocused, titleDraft != next { titleDraft = next }
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
            allowlistExpanded = false
            resetTitle()
        }
        .onChange(of: model.savedCopy != nil) { _, saved in
            if saved {
                pendingDelete = false
                deletionTarget = nil
            }
        }
    }

    private func identity(_ chat: ChatConversation) -> some View {
        ChatSetupSection(title: L10n.text("apple.chatinspector.conversation.ccca1817"), icon: .comment,
                         primary: titleField(chat)) {
            Text(chat.title).font(Theme.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if chat.running {
                Text(L10n.text("common.working"))
                    .font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func titleField(_ chat: ChatConversation) -> some View {
        let owner = model.currentReference
        let text = Binding(get: { titleDraft }, set: { next in
            guard let owner, titleOwner == owner, model.currentReference == owner else { return }
            titleDraft = next
        })
        return HStack(spacing: Theme.Space.s) {
            TextField(L10n.text("apple.chatinspector.title.7e8cd205"), text: text)
                .themedFieldBox()
                .disabled(model.savedCopy != nil)
                .focused($titleFocused)
                .onSubmit { commitTitle(chat) }
            Button(L10n.text("apple.chatinspector.personas.fa2ea3fb"), .persona) { showingPersonas = true }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .environment(\.compactActions, true)
                .help(L10n.text("apple.chatinspector.personas.fa2ea3fb"))
        }
    }

    @ViewBuilder
    private var folderCard: some View {
        ChatSetupSection(title: L10n.text("apple.chatinspector.folder.74ccd433"), icon: .reveal,
                         summary: folder?.name, primary: folderActions) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(folder?.name ?? L10n.text("apple.chatinspector.this_project.d0f62545"))
                    .font(Theme.callout.weight(.medium))
                if let path = folder?.path, !path.isEmpty {
                    Text(path)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let machine = folder?.machineLabel, !machine.isEmpty {
                    Label(machine, systemImage: "desktopcomputer").font(Theme.caption).foregroundStyle(.secondary)
                }
                if let branch = folder?.git?.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var folderActions: some View {
        if let path = folder?.path, !path.isEmpty {
            HStack(spacing: Theme.Space.s) {
                Text(path).font(Theme.mono(11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.text("common.chat.inspector.copy_path"), .copy) { ChatClipboard.copy(path) }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
    }

    private func allowlist(_ chat: ChatConversation) -> some View {
        ChatSetupSection(title: L10n.text("apple.chatinspector.always_allowed.94387772"), icon: .settings,
              summary: chat.allowedTools.isEmpty && chat.allowedShellPrefixes.isEmpty
              ? L10n.text("apple.chatinspector.nothing_is_remembered_yet.d523b614")
              : L10n.text("common.chat.inspector.allowed_summary", chat.allowedTools.count.formatted(), chat.allowedShellPrefixes.count.formatted()),
              expanded: $allowlistExpanded, primary: allowlistActions(chat)) {
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
                                removeAllowed(tool, shellPrefix: false, from: chat)
                            }
                        }
                        ForEach(chat.allowedShellPrefixes, id: \.self) { prefix in
                            allowChip(prefix) {
                                removeAllowed(prefix, shellPrefix: true, from: chat)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func allowlistActions(_ chat: ChatConversation) -> some View {
        let remembered = chat.allowedTools + chat.allowedShellPrefixes
        if !remembered.isEmpty {
            HStack(spacing: Theme.Space.s) {
                Text(remembered.prefix(3).joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !allowlistExpanded {
                    Button(L10n.text("common.edit"), .edit) { allowlistExpanded = true }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(model.savedCopy != nil || writingAllowlist)
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
                .disabled(model.savedCopy != nil || writingAllowlist)
                .buttonStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.accentSoft, in: Capsule())
    }

    private func removeAllowed(_ value: String, shellPrefix: Bool, from chat: ChatConversation) {
        guard !writingAllowlist, let owner = model.currentReference else { return }
        writingAllowlist = true
        Task {
            defer { writingAllowlist = false }
            guard model.currentReference == owner, model.savedCopy == nil,
                  let current = model.selected, current.id == chat.id else { return }
            if shellPrefix {
                await model.update(allowedShellPrefixes: current.allowedShellPrefixes.filter { $0 != value })
            } else {
                await model.update(allowedTools: current.allowedTools.filter { $0 != value })
            }
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
        guard let titleOwner, titleOwner == model.currentReference,
              model.selected?.id == chat.id else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != chat.title else {
            if title.isEmpty { titleDraft = chat.title }
            return
        }
        change(chat) { await model.update(title: title) }
    }

    private func resetTitle() {
        titleFocused = false
        titleOwner = model.currentReference
        titleDraft = model.selected?.title ?? ""
    }
}
