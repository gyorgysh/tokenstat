// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Cheap project metadata, independent of a selected transcript. This cache
/// belongs to the signed-in scene alongside its connection and chat readers.
@MainActor
@Observable
final class ClientProjectChats {
    struct Key: Hashable { let peer: String; let workspace: String }

    @MainActor @Observable
    final class Entry {
        let key: Key
        private(set) var chats: [ChatConversation] = []
        private(set) var loaded = false
        private(set) var refreshing = false
        private(set) var error: String?
        var expanded = false
        @ObservationIgnored private let flight = Singleflight<Void>()
        @ObservationIgnored private var lastSuccess: Date?
        @ObservationIgnored private var revision: UInt64 = 0
        @ObservationIgnored private var viewers: Set<UUID> = []
        @ObservationIgnored private var interactions: Set<UUID> = []
        @ObservationIgnored private var heldIDs: [String]?
        @ObservationIgnored private var holdUntil = Date.distantPast
        @ObservationIgnored private var incoming: [ChatConversation] = []

        init(key: Key) { self.key = key }
        func appear(_ owner: UUID) { viewers.insert(owner) }
        func disappear(_ owner: UUID) { viewers.remove(owner); interactions.remove(owner) }
        var canDiscard: Bool { viewers.isEmpty && !flight.isRunning }

        func interacting(_ active: Bool, owner: UUID, now: Date = Date()) {
            if active {
                if heldIDs == nil { heldIDs = chats.map(\.id) }
                interactions.insert(owner)
            } else {
                interactions.remove(owner)
                // Covers lifting a finger into a context menu and a queued
                // refresh completing just as the touch ends.
                holdUntil = now.addingTimeInterval(2)
            }
        }

        func load(refresh: Bool = false,
                  clock: @escaping @MainActor @Sendable () -> Date = { Date() },
                  isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
                  read: @escaping @MainActor @Sendable () async throws -> [ChatConversation]) async {
            let now = clock()
            guard refresh || !loaded || error != nil || lastSuccess.map({ now.timeIntervalSince($0) >= 5 }) != false else { return }
            await flight.run { [self] in
                guard isCurrent() else { return }
                let requestedRevision = revision
                refreshing = true
                defer { refreshing = false }
                do {
                    let list = try await read()
                    guard isCurrent(), revision == requestedRevision else { return }
                    incoming = list.filter { !$0.id.isEmpty && $0.workspaceID == key.workspace }
                    let completedAt = clock()
                    publish(now: completedAt)
                    loaded = true
                    error = nil
                    lastSuccess = completedAt
                } catch {
                    guard isCurrent(), revision == requestedRevision else { return }
                    self.error = error.localizedDescription
                    loaded = true
                }
            }
        }

        /// A mutation invalidates any read already on the wire before acting.
        func invalidate() { revision &+= 1; lastSuccess = nil }
        func replace(_ chat: ChatConversation) {
            invalidate()
            incoming.removeAll { $0.id == chat.id }
            incoming.append(chat)
            publish(now: Date())
        }
        func remove(_ id: String) {
            invalidate()
            incoming.removeAll { $0.id == id }
            publish(now: Date())
        }

        private func publish(now: Date) {
            if interactions.isEmpty, now >= holdUntil { heldIDs = nil }
            let recent = incoming.sorted {
                let left = $0.lastMessageAtMs ?? $0.updatedAtMs
                let right = $1.lastMessageAtMs ?? $1.updatedAtMs
                return left == right ? $0.id < $1.id : left > right
            }
            let next = StableListOrder.holding(recent, ids: heldIDs)
            if next != chats { chats = next }
        }
    }

    @ObservationIgnored private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var recency: [Key] = []
    private let limit: Int
    init(limit: Int = 12) { self.limit = max(1, limit) }

    func entry(peer: String, workspace: String) -> Entry {
        let key = Key(peer: peer, workspace: workspace)
        recency.removeAll { $0 == key }
        recency.append(key)
        if let entry = entries[key] { return entry }
        for candidate in recency.dropLast() where entries.count >= limit {
            guard entries[candidate]?.canDiscard == true else { continue }
            entries.removeValue(forKey: candidate)
        }
        recency.removeAll { entries[$0] == nil && $0 != key }
        let entry = Entry(key: key)
        entries[key] = entry
        return entry
    }
}
