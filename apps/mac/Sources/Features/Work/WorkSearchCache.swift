// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Coordinates the local cache transport with disposable search indexes.
/// Loading is paused across mutations because a put can evict another scope.
/// Unaffected indexed records remain available rather than rebuilding on every
/// saved page. Callers still supply current folder access to the index.
actor WorkSearchCache {
    static let shared = WorkSearchCache()

    struct Subscription: Sendable {
        let id: UUID
        let index: WorkSearchIndex
    }

    struct Read: Sendable {
        fileprivate let subscription: UUID
        fileprivate let epoch: UUID
        fileprivate let load: WorkSearchIndex.Load
    }

    private struct Registered {
        let scope: WorkReference.Scope
        let index: WorkSearchIndex
    }

    private var registered: [UUID: Registered] = [:]
    private var mutations = Set<UUID>()
    private var epoch = UUID()
    private var observers: [UUID: AsyncStream<UUID>.Continuation] = [:]

    func changes() -> AsyncStream<UUID> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }


    func subscribe(scope: WorkReference.Scope, folders: Set<WorkSearchIndex.Folder>) -> Subscription {
        let id = UUID()
        let index = WorkSearchIndex(scope: scope, folders: folders)
        registered[id] = Registered(scope: scope, index: index)
        return Subscription(id: id, index: index)
    }

    func unsubscribe(_ subscription: Subscription) async {
        let removed = registered.removeValue(forKey: subscription.id)
        await removed?.index.clear()
    }

    func snapshotEpoch() -> UUID? { mutations.isEmpty ? epoch : nil }

    func reconcile(_ subscription: Subscription, references: Set<WorkReference>, at captured: UUID) async -> Bool {
        guard mutations.isEmpty, captured == epoch,
              let item = registered[subscription.id] else { return false }
        await item.index.retainSavedWork(references)
        return mutations.isEmpty && captured == epoch && registered[subscription.id] != nil
    }

    func beginRead(_ subscription: Subscription, reference: WorkReference) async -> Read? {
        guard mutations.isEmpty, let item = registered[subscription.id] else { return nil }
        let captured = epoch
        guard let load = await item.index.beginLoad(reference), captured == epoch,
              mutations.isEmpty, registered[subscription.id] != nil else { return nil }
        return Read(subscription: subscription.id, epoch: captured, load: load)
    }

    @discardableResult
    func finishRead(_ read: Read, documents: [WorkSearchIndex.Document]) async -> Bool {
        guard mutations.isEmpty, epoch == read.epoch,
              let item = registered[read.subscription] else { return false }
        return await item.index.replace(read.load, documents: documents)
    }

    func revokeHost(_ host: String, scope: WorkReference.Scope) async {
        epoch = UUID()
        for item in registered.values where item.scope == scope {
            await item.index.revokeHost(host)
        }
        for observer in observers.values { observer.yield(epoch) }
    }

    func discardAfterRepair() async {
        let token = await beginMutation()
        await finishMutation(token, scope: "", uncertain: true)
    }

    func beginMutation() async -> UUID {
        let token = UUID()
        mutations.insert(token)
        epoch = UUID()
        for item in registered.values { await item.index.invalidateLoads() }
        return token
    }

    /// An uncertain mutation clears indexes conservatively: a failed reply
    /// cannot prove that the host did not commit or evict before disconnecting.
    func finishMutation(_ token: UUID, scope: String, changedIDs: [String] = [],
                        evicted: [String] = [], cleared: Bool = false,
                        uncertain: Bool = false) async {
        guard mutations.contains(token) else { return }
        for item in registered.values {
            let wireScope = WorkCache.scope(for: item.scope)
            if uncertain || (cleared && wireScope == scope) {
                await item.index.clear()
                continue
            }
            var ids = wireScope == scope ? changedIDs : []
            let prefix = wireScope + "|"
            ids += evicted.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            for id in Set(ids) {
                if let reference = WorkCache.reference(recordID: id, scope: item.scope) {
                    await item.index.remove(reference)
                }
            }
        }
        mutations.remove(token)
        epoch = UUID()
        for observer in observers.values { observer.yield(epoch) }
    }
}
