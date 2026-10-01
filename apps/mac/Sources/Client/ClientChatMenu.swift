// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientChatMenu: View {
    let model: ChatModel
    let conversation: ChatConversation
    let peer: String
    let workspaceID: String
    var onFork: ((ChatConversation) -> Void)?
    @State private var rename = false
    @State private var supportsFork = false
    @State private var copying = false
    @State private var owner = WorkSessionContext.shared.scope
    var body: some View {
        Menu {
            Button(L10n.text("apple.clientchatmenu.rename_chat.26076241"), .edit) { rename = true }.disabled(conversation.running)
            if supportsFork {
                Button(L10n.text("apple.clientchatmenu.fork_chat.dfbcbb35"), .copy) {
                    copying = true
                    Task {
                        defer { copying = false }
                        guard owner != nil, owner == WorkSessionContext.shared.scope else { return }
                        do {
                            let copied = try await model.fork(conversation, in: workspaceID, peer: peer)
                            guard owner == WorkSessionContext.shared.scope, model.peer == peer,
                                  model.workspaceID == workspaceID else { return }
                            onFork?(copied)
                        } catch { model.error = error.localizedDescription }
                    }
                }.disabled(copying)
            }
        } label: {
            ActionIcon.more.label(L10n.text("apple.clientchatmenu.chat_actions.8ba35bb8"))
                .environment(\.compactActions, true)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .task(id: peer) { supportsFork = await RemoteHostFeature.chatFork.isSupported(peer: peer) }
        .sheet(isPresented: $rename) {
            ClientNameEditor(title: L10n.text("apple.clientchatmenu.rename_chat.26076241"), initial: conversation.title) { title in
                guard owner != nil, owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                try await model.rename(conversation, in: workspaceID, to: title, peer: peer)
            }
        }
    }
}
#endif
