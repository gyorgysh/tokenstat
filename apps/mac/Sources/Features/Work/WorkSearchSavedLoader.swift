// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Opens one encrypted page at a time on the local transport. The caller
/// supplies authorized folder labels and machine identities before loading.
/// No account refresh, pairing or peer request is part of saved-work search.
actor WorkSearchSavedLoader {
    struct Coverage: Sendable {
        let eligible: Int
        let indexed: Int
        let unreadable: Int
        let interrupted: Bool
        let repaired: Bool
    }

    enum Failure: Error { case locked, wrongRecord }
    typealias ListRecords = @Sendable (String) async throws -> CacheListResult
    typealias ReadRecord = @Sendable (String, String) async throws -> CachedRecord

    typealias ReadChange = @Sendable (String, String) async throws -> WorkViewedChange.Record

    private let cache: WorkSearchCache
    private let subscription: WorkSearchCache.Subscription
    private let scope: WorkReference.Scope
    private let folders: [WorkSearchIndex.Folder: String]
    private let machines: [String: String]
    private let list: ListRecords
    private let read: ReadRecord
    private let readChange: ReadChange
    private var generation = UUID()

    init(cache: WorkSearchCache = .shared, subscription: WorkSearchCache.Subscription,
         scope: WorkReference.Scope, folders: [WorkSearchIndex.Folder: String],
         machines: [String: String], list: @escaping ListRecords = { try await Bridge.cacheList(scope: $0) },
         read: @escaping ReadRecord = { scope, id in
             guard let key = WorkCacheKey.existingKey(for: scope) else { throw Failure.locked }
             return try await Bridge.cacheGet(key: WorkCacheKey.encoded(key), scope: scope, id: id)
         }, readChange: @escaping ReadChange = { scope, id in
             guard let key = WorkCacheKey.existingKey(for: scope) else { throw Failure.locked }
             return try await Bridge.cachedChange(key: WorkCacheKey.encoded(key), scope: scope, id: id)
         }) {
        self.cache = cache
        self.subscription = subscription
        self.scope = scope
        self.folders = folders
        self.machines = machines
        self.list = list
        self.read = read
        self.readChange = readChange
    }

    func cancel() { generation = UUID() }

    func load() async throws -> Coverage {
        let run = UUID()
        generation = run
        let wireScope = WorkCache.scope(for: scope)
        guard let epoch = await cache.snapshotEpoch() else {
            return Coverage(eligible: 0, indexed: 0, unreadable: 0, interrupted: true, repaired: false)
        }
        let listing = try await list(wireScope)
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
        let eligible = listing.records.compactMap { record -> (CacheRecordMeta, WorkReference)? in
            guard record.scope == wireScope,
                  let reference = WorkCache.reference(recordID: record.id, scope: scope),
                  WorkCache.matches(kind: record.kind, reference: reference),
                  reference.itemID == record.itemId,
                  folders[.init(hostIdentity: reference.hostIdentity, workspaceID: reference.workspaceID)] != nil,
                  machines[reference.hostIdentity] != nil else { return nil }
            return (record, reference)
        }
        guard await cache.reconcile(subscription, references: Set(eligible.map { $0.1 }), at: epoch) else {
            return Coverage(eligible: eligible.count, indexed: 0, unreadable: 0, interrupted: true, repaired: listing.repaired)
        }
        var indexed = 0
        var unreadable = 0
        for (meta, reference) in eligible {
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            guard let ticket = await cache.beginRead(subscription, reference: reference) else {
                return Coverage(eligible: eligible.count, indexed: indexed, unreadable: unreadable,
                                interrupted: true, repaired: listing.repaired)
            }
            do {
                let folderName = folders[.init(hostIdentity: reference.hostIdentity, workspaceID: reference.workspaceID)] ?? ""
                let machineName = machines[reference.hostIdentity] ?? ""
                let documents: [WorkSearchIndex.Document]
                if reference.kind == .conversation {
                    let record = try await read(wireScope, meta.id)
                    guard record.scope == wireScope, record.id == meta.id, record.kind == "conversation",
                          record.itemId == reference.itemID, record.revision == record.payload.revision else {
                        throw Failure.wrongRecord
                    }
                    documents = WorkSearchConversation.documents(reference: reference, payload: record.payload,
                        folderName: folderName, machineName: machineName)
                } else {
                    let record = try await readChange(wireScope, meta.id)
                    guard record.matches(reference) else { throw Failure.wrongRecord }
                    documents = record.payload.documents(folderName: folderName, machineName: machineName)
                }
                try Task.checkCancellation()
                guard generation == run else { throw CancellationError() }
                guard await cache.finishRead(ticket, documents: documents) else {
                    return Coverage(eligible: eligible.count, indexed: indexed, unreadable: unreadable,
                                    interrupted: true, repaired: listing.repaired)
                }
                indexed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch Failure.locked {
                guard generation == run, !Task.isCancelled else { throw CancellationError() }
                await subscription.index.clear()
                throw Failure.locked
            } catch {
                if generation != run || Task.isCancelled { throw CancellationError() }
                // Retaining old excerpts after a failed decrypt would make an
                // unreadable or externally removed record appear searchable.
                _ = await cache.finishRead(ticket, documents: [])
                unreadable += 1
            }
            await Task.yield()
        }
        return Coverage(eligible: eligible.count, indexed: indexed, unreadable: unreadable,
                        interrupted: false, repaired: listing.repaired)
    }
}
