// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// Chat ownership belongs to the signed-in scene, above its changing layout.
/// A folder list and a standalone recent-chat reader have separate owners:
/// opening a notification must not select a different chat underneath it.
@MainActor
@Observable
final class ClientChatSession {
    var model = ChatModel()
    var loaded = false
    var opened: ChatConversation?
    var retainedThread: ChatConversation?

    @ObservationIgnored private let loading = Singleflight<Void>()
    @ObservationIgnored private let opening = Singleflight<Void>()
    @ObservationIgnored private var viewers: Set<UUID> = []
    @ObservationIgnored private var reusable = false

    func appear(_ viewer: UUID) { viewers.insert(viewer) }
    func disappear(_ viewer: UUID) {
        viewers.remove(viewer)
        model.saveDraftNow()
    }

    var canDiscard: Bool {
        viewers.isEmpty && !loading.isRunning && !opening.isRunning && !model.busy && !model.sending
            && !model.isCreating && !model.openingConversation
            && model.unconfirmedSend == nil
            && model.draft.isEmpty && model.attachments.isEmpty
            && model.stagingAttachments == 0 && model.pendingQueue.isEmpty
    }

    /// A cancelled layout waiter leaves the shared read alive for its successor.
    func load(workspaceID: String, peer: String, refresh: Bool = false) async {
        guard refresh || !reusable || model.error != nil || model.peer != peer
            || !model.isReady(for: workspaceID) else { return }
        await loading.run { [self] in
            model.error = nil
            await model.load(workspaceID: workspaceID, peer: peer, selectFirst: false)
            loaded = true
            reusable = model.error == nil && model.peer == peer && model.isReady(for: workspaceID)
        }
    }

    func openMostRecent() async {
        guard opened == nil else { return }
        await opening.run { [self] in
            if let recent = model.mostRecent {
                if model.selected?.id != recent.id { await model.select(recent) }
                guard model.selected?.id == recent.id else { return }
                opened = recent
            } else if let created = await model.create(), model.selected?.id == created.id {
                opened = created
            }
        }
    }
}

@MainActor
@Observable
final class ClientChatSessions {
    struct Key: Hashable {
        let peer: String
        let workspace: String
        let conversation: String?
    }

    // Reading the cache from a view must not invalidate that same view.
    @ObservationIgnored private var sessions: [Key: ClientChatSession] = [:]
    @ObservationIgnored private var recency: [Key] = []
    private let limit: Int

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func session(peer: String, workspace: String, conversation: String? = nil) -> ClientChatSession {
        let key = Key(peer: peer, workspace: workspace, conversation: conversation)
        recency.removeAll { $0 == key }
        recency.append(key)
        if let session = sessions[key] { return session }
        // Bound inactive readers; active work and unsent writing remain owned.
        for candidate in recency.dropLast() where sessions.count >= limit {
            guard let old = sessions[candidate], old.canDiscard else { continue }
            sessions.removeValue(forKey: candidate)
        }
        recency.removeAll { sessions[$0] == nil && $0 != key }
        let session = ClientChatSession()
        sessions[key] = session
        return session
    }
}
