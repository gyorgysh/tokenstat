// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

#if !os(macOS)
@MainActor @Observable
final class ClientChatPresentationState {
    var sidebarVisible = true
    var sidebarWidth: CGFloat = 210
    var restoreSidebarAfterCompanion = false
    var companion: String?
    var focus = "split"
    var chatFraction: CGFloat = 0.5
    var browserSheetVisible = false
    var chromeCollapsed = false
}
#endif

@MainActor
@Observable
final class ClientChatSession {
    var model = ChatModel()
    var loaded = false
    var opened: ChatConversation?
    var retainedThread: ChatConversation?
    #if !os(macOS)
    var presentation = ClientChatPresentationState()
    var browserSession: ProjectBrowserSession?
    #endif

    @ObservationIgnored private let loading = Singleflight<Void>()
    @ObservationIgnored private let opening = Singleflight<Void>()
    @ObservationIgnored private var selecting: (chatID: String, model: ChatModel, ticket: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var viewers: Set<UUID> = []
    @ObservationIgnored private var reusable = false
    @ObservationIgnored private var revision: UInt64 = 0

    func appear(_ viewer: UUID) {
        viewers.insert(viewer)
    }
    func disappear(_ viewer: UUID) {
        let removed = viewers.remove(viewer) != nil
        model.saveDraftNow()
        if removed && viewers.isEmpty { model.cancelFileTransferForDeparture() }
    }

    func deactivate() {
        #if !os(macOS)
        browserSession?.close()
        browserSession = nil
        #endif
    }

    var canDiscard: Bool {
        return viewers.isEmpty && !loading.isRunning && !opening.isRunning
            && selecting == nil && !model.busy && !model.sending
            && (opened == nil || opened?.id == model.selected?.id)
            && !model.isCreating && !model.openingConversation
            && model.unconfirmedSend == nil
            && model.draft.isEmpty && model.attachments.isEmpty
            && model.stagingAttachments == 0 && model.pendingQueue.isEmpty
    }

    func load(workspaceID: String, peer: String, refresh: Bool = false) async {
        guard refresh || !reusable || model.error != nil || model.peer != peer
            || !model.isReady(for: workspaceID) else { return }
        await loading.run { [self] in
            let requestedRevision = revision
            model.error = nil
            await model.load(workspaceID: workspaceID, peer: peer, selectFirst: false)
            loaded = true
            reusable = revision == requestedRevision && model.error == nil && model.peer == peer && model.isReady(for: workspaceID)
        }
    }

    func openMostRecent() async {
        guard opened == nil else { return }
        await opening.run { [self] in
            if let recent = model.mostRecent {
                if model.selected?.id != recent.id { await select(recent) }
                guard opened == nil, model.selected?.id == recent.id else { return }
                opened = recent
            } else if let created = await model.create(), opened == nil, model.selected?.id == created.id {
                opened = created
            }
        }
    }

    func select(_ chat: ChatConversation) async {
        guard !Task.isCancelled else { return }
        if let selecting, selecting.chatID == chat.id, selecting.model === model {
            await selecting.task.value
            return
        }
        selecting?.task.cancel()
        let reader = model
        let ticket = UUID()
        let task = Task { await reader.select(chat) }
        selecting = (chat.id, reader, ticket, task)
        await task.value
        if selecting?.ticket == ticket { selecting = nil }
    }

    func invalidate() { revision &+= 1; reusable = false }
}

@MainActor
@Observable
final class ClientChatSessions {
    struct Key: Hashable {
        let peer: String
        let workspace: String
        let conversation: String?

        func matches(_ reference: WorkReference) -> Bool {
            reference.kind == .conversation && peer == reference.hostIdentity
                && workspace == reference.workspaceID
                && (conversation == nil || conversation == reference.itemID)
        }

        func isStandaloneReader(for reference: WorkReference?) -> Bool {
            guard let reference, reference.kind == .conversation,
                  peer == reference.hostIdentity, workspace == reference.workspaceID,
                  let conversation else { return false }
            return conversation == reference.itemID
        }
    }

    @ObservationIgnored private var sessions: [Key: ClientChatSession] = [:]
    @ObservationIgnored private var recency: [Key] = []
    private let limit: Int

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func session(peer: String, workspace: String, conversation: String? = nil,
                 retaining: ClientChatSession? = nil) -> ClientChatSession {
        let key = Key(peer: peer, workspace: workspace, conversation: conversation)
        recency.removeAll { $0 == key }
        recency.append(key)
        if let retaining { sessions[key] = retaining }
        if let session = sessions[key] { return session }
        for candidate in recency.dropLast() where sessions.count >= limit {
            guard let old = sessions[candidate], old.canDiscard else { continue }
            old.deactivate()
            sessions.removeValue(forKey: candidate)
        }
        recency.removeAll { sessions[$0] == nil && $0 != key }
        let session = ClientChatSession()
        sessions[key] = session
        return session
    }

    func deactivate() {
        for session in sessions.values { session.deactivate() }
        sessions.removeAll()
        recency.removeAll()
    }

    func created(_ chat: ChatConversation, peer: String, workspace: String, by creator: ClientChatSession) {
        for (key, session) in sessions where key.peer == peer && key.workspace == workspace && session !== creator {
            session.invalidate()
            session.model.acceptRenamedConversation(chat)
        }
    }

    func renamed(_ chat: ChatConversation, peer: String, workspace: String) {
        for (key, session) in sessions where key.peer == peer && key.workspace == workspace {
            session.invalidate()
            session.model.acceptRenamedConversation(chat)
            if session.opened?.id == chat.id { session.opened = chat }
            if session.retainedThread?.id == chat.id { session.retainedThread = chat }
        }
    }

    func removed(_ id: String, peer: String, workspace: String) async {
        for (key, session) in sessions where key.peer == peer && key.workspace == workspace {
            session.invalidate()
            if session.opened?.id == id { session.opened = nil }
            if session.retainedThread?.id == id { session.retainedThread = nil }
            await session.model.forgetRemovedConversation(id)
        }
    }
}
