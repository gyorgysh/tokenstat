// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Held above both mobile layouts. A menu always acts on its original row.
struct ClientProjectChatAction: Identifiable {
    enum Kind { case rename, delete }
    let id = UUID()
    let scope: WorkReference.Scope
    let peer: String
    let workspaceID: String
    let hostName: String
    let chat: ChatConversation
    let kind: Kind
}

struct ClientProjectChatActions: ViewModifier {
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientChatSessions.self) private var readers
    @Environment(ClientProjectChats.self) private var projects
    @State private var error: String?
    @State private var errorOwner: WorkReference.Scope?

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { navigation.projectChatAction.flatMap { $0.kind == .rename ? $0 : nil } },
                set: { if $0 == nil, navigation.projectChatAction?.kind == .rename { navigation.projectChatAction = nil } }
            )) { target in
                ClientNameEditor(title: L10n.text("apple.clientchatmenu.rename_chat.26076241"), initial: target.chat.title) { name in
                    let session = try await ready(target)
                    let entry = projects.entry(peer: target.peer, workspace: target.workspaceID)
                    entry.invalidate()
                    try await session.model.rename(target.chat, in: target.workspaceID, to: name, peer: target.peer)
                    guard target.scope == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                    if let updated = session.model.chats.first(where: { $0.id == target.chat.id }) {
                        entry.replace(updated)
                        readers.renamed(updated, peer: target.peer, workspace: target.workspaceID)
                    }
                }
            }
            .confirmationDialog(L10n.text("apple.clientchatview.delete_this_chat.848dad9b"),
                isPresented: Binding(
                    get: { navigation.projectChatAction?.kind == .delete },
                    set: { if !$0, navigation.projectChatAction?.kind == .delete { navigation.projectChatAction = nil } }
                ), titleVisibility: .visible) {
                    if let target = navigation.projectChatAction, target.kind == .delete {
                        Button(L10n.text("apple.clientchatview.delete_chat.93291d9c"), role: .destructive) {
                            navigation.projectChatAction = nil
                            Task { await remove(target) }
                        }
                    }
                    Button(L10n.text("apple.clientchatview.keep_it.fdce5da2"), role: .cancel) { navigation.projectChatAction = nil }
                } message: {
                    Text(navigation.projectChatAction?.chat.title ?? "")
                }
            .alert(L10n.text("apple.clientprojectchatactions.chat_action_failed"), isPresented: Binding(
                get: { error != nil && errorOwner == WorkSessionContext.shared.scope },
                set: { if !$0 { error = nil } }
            )) {
                Button(L10n.text("common.close"), role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func ready(_ target: ClientProjectChatAction) async throws -> ClientChatSession {
        guard target.scope == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
        let session = readers.session(peer: target.peer, workspace: target.workspaceID)
        await session.load(workspaceID: target.workspaceID, peer: target.peer)
        guard target.scope == WorkSessionContext.shared.scope,
              session.model.peer == target.peer, session.model.isReady(for: target.workspaceID) else {
            throw ClientActionOwnership.changed
        }
        if let message = session.model.error {
            throw NSError(domain: "Chat", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return session
    }

    private func remove(_ target: ClientProjectChatAction) async {
        do {
            let session = try await ready(target)
            let entry = projects.entry(peer: target.peer, workspace: target.workspaceID)
            entry.invalidate()
            let removed = await session.model.remove(target.chat, in: target.workspaceID)
            guard target.scope == WorkSessionContext.shared.scope else { return }
            guard removed else {
                throw NSError(domain: "Chat", code: 1, userInfo: [NSLocalizedDescriptionKey: session.model.error ?? L10n.text("apple.clientprojectchatactions.chat_action_failed")])
            }
            entry.remove(target.chat.id)
            await readers.removed(target.chat.id, peer: target.peer, workspace: target.workspaceID)
            guard target.scope == WorkSessionContext.shared.scope else { return }
            if let shown = navigation.presentedChat,
               shown.peer == target.peer, shown.workspaceID == target.workspaceID, shown.chatID == target.chat.id {
                navigation.presentedChat = nil
            }
            if navigation.requestedChat == navigation.reference(peer: target.peer, workspaceID: target.workspaceID, chatID: target.chat.id) {
                navigation.requestedChat = nil
            }
        } catch {
            guard target.scope == WorkSessionContext.shared.scope else { return }
            errorOwner = target.scope
            self.error = ClientTunnelCopy.display(error.localizedDescription, host: target.hostName)
        }
    }
}
#endif
