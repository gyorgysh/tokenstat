// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientChatMenu: View {
    let model: ChatModel
    let conversation: ChatConversation
    let peer: String
    let workspaceID: String
    var hostName = ""
    var onFork: ((ChatConversation) -> Void)?
    var onSetup: (() -> Void)?
    var onHandoff: (() -> Void)?
    var onDelete: ((ChatConversation) -> Void)?
    var onViewportChoice: (() -> Void)?
    @State private var rename = false
    @State private var supportsFork = false
    @State private var copying = false
    @State private var removing = false
    @State private var pendingDelete: ChatConversation?
    @State private var owner = WorkSessionContext.shared.scope
    @State private var visible = false
    @Environment(ClientNavigationModel.self) private var navigation

    private var ownsProject: Bool {
        owner != nil && owner == WorkSessionContext.shared.scope
            && model.peer == peer && model.workspaceID == workspaceID && model.savedCopy == nil
    }

    var body: some View {
        Menu {
            Button(L10n.text("apple.clientchatmenu.rename_chat.26076241"), .edit) { rename = true }
                .disabled(conversation.running || !ownsProject)
            if supportsFork {
                Button(L10n.text("apple.clientchatmenu.fork_chat.dfbcbb35"), .copy) {
                    let ticket = navigation.chatActionTicket()
                    copying = true
                    Task {
                        defer { copying = false }
                        @MainActor func isCurrent() -> Bool {
                            visible && !Task.isCancelled && ownsProject
                                && navigation.acceptsChatAction(ticket)
                        }
                        guard isCurrent() else { return }
                        do {
                            let copied = try await model.fork(conversation, in: workspaceID, peer: peer)
                            guard isCurrent() else { return }
                            onFork?(copied)
                        } catch {
                            if isCurrent() { model.error = error.localizedDescription }
                        }
                    }
                }.disabled(copying || !ownsProject)
            }
            if onSetup != nil || onHandoff != nil {
                Divider()
                if let onSetup {
                    Button(L10n.text("apple.clientchatview.setup.7013af4c"), .settings, action: onSetup)
                }
                if let onHandoff {
                    Button(L10n.text("apple.clientchatview.continue_on_another_device.b5836f9a"), .device, action: onHandoff)
                }
            }
            Section {
                ChatDetailMenuPicker()
                Button(
                    model.anyGroupOpen ? L10n.text("apple.chatdetail.collapse_steps") : L10n.text("apple.chatdetail.expand_steps"),
                    model.anyGroupOpen ? .collapse : .preview
                ) {
                    onViewportChoice?()
                    model.setAllGroups(open: !model.anyGroupOpen)
                }
            }
            if onDelete != nil {
                Divider()
                Button(L10n.text("apple.clientchatview.delete_chat.93291d9c"), .delete, role: .destructive) {
                    pendingDelete = conversation
                }.disabled(!ownsProject)
            }
        } label: {
            Label(L10n.text("apple.clientchatmenu.chat_actions.8ba35bb8"), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .disabled(removing)
        .accessibilityLabel(L10n.text("apple.clientchatmenu.chat_actions.8ba35bb8"))
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: peer) { supportsFork = await RemoteHostFeature.chatFork.isSupported(peer: peer) }
        .sheet(isPresented: $rename) {
            ClientNameEditor(title: L10n.text("apple.clientchatmenu.rename_chat.26076241"), initial: conversation.title) { title in
                guard ownsProject else { throw ClientActionOwnership.changed }
                try await model.rename(conversation, in: workspaceID, to: title, peer: peer)
            }
        }
        .confirmationDialog(
            L10n.text("apple.clientchatview.delete_this_chat.848dad9b"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.clientchatview.delete_chat.93291d9c"), role: .destructive) {
                guard let chat = pendingDelete else { return }
                pendingDelete = nil
                removing = true
                Task {
                    defer { removing = false }
                    guard ownsProject else { return }
                    let removed = await model.remove(chat, in: workspaceID)
                    guard removed, ownsProject else { return }
                    onDelete?(chat)
                }
            }
            Button(L10n.text("apple.clientchatview.keep_it.fdce5da2"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.text("apple.clientchatview.the_transcript_stays_on_0_until_you_delete.2ccfbdf7",
                           hostName.isEmpty ? L10n.text("apple.clientchatview.the_computer.da52d93a") : hostName))
        }
    }
}
#endif
