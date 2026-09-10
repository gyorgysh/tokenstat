// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkSearchSavedLoader.swift WorkSearchCache.swift WorkSearchIndex.swift WorkSearchText.swift WorkReference.swift WorkCache.swift.
import Foundation

struct CacheRecordMeta: Sendable { let scope: String; let id: String; let kind: String; let itemId: String }
struct CacheListResult: Sendable { let records: [CacheRecordMeta]; let repaired: Bool }
struct CachedRecordPayload: Sendable { let revision: String }
struct CachedRecord: Sendable {
    let scope: String; let id: String; let kind: String; let itemId: String
    let revision: String?; let payload: CachedRecordPayload
}
enum WorkCacheKey {
    static func existingKey(for: String) -> String? { nil }
    static func encoded(_ value: String) -> String { value }
}
struct WorkViewedChange: Sendable {
    struct Record: Sendable {
        var payload: WorkViewedChange { .init() }
        func matches(_ reference: WorkReference) -> Bool { false }
    }
    func documents(folderName: String, machineName: String) -> [WorkSearchIndex.Document] { [] }
}
enum Bridge {
    static func cachedChange(key: String, scope: String, id: String) async throws -> WorkViewedChange.Record { fatalError("Injected local transport required") }
    static func cacheList(scope: String) async throws -> CacheListResult { fatalError("Injected local transport required") }
    static func cacheGet(key: String, scope: String, id: String) async throws -> CachedRecord { fatalError("Injected local transport required") }
}
enum WorkSearchConversation {
    static func documents(reference: WorkReference, payload: CachedRecordPayload, folderName: String,
                          machineName: String) -> [WorkSearchIndex.Document] {
        [.init(reference: reference, revision: payload.revision, title: "Needle", text: "Saved words",
               folderName: folderName, machineName: machineName, updatedAt: Date(), partial: true)]
    }
}
actor Transport {
    var records: [CacheRecordMeta] = []
    var reads: [String] = []
    var failing = false
    var locked = false
    private var shouldPause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func pauseNextRead() { shouldPause = true }
    func waitForRead() async {
        if paused != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resumeRead() { paused?.resume(); paused = nil }
    func setLocked(_ value: Bool) { locked = value }
    func configure(_ records: [CacheRecordMeta], failing: Bool = false) {
        self.records = records; self.failing = failing
    }
    func list(_ scope: String) -> CacheListResult { .init(records: records, repaired: false) }
    func read(_ scope: String, _ id: String) async throws -> CachedRecord {
        reads.append(id)
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { paused = $0; started?.resume(); started = nil }
        }
        if locked { throw WorkSearchSavedLoader.Failure.locked }
        if failing { throw WorkSearchSavedLoader.Failure.wrongRecord }
        let record = records.first { $0.id == id }!
        return .init(scope: scope, id: id, kind: record.kind, itemId: record.itemId,
                     revision: "r1", payload: .init(revision: "r1"))
    }
}
@main struct WorkSearchSavedLoaderTests {
    static func main() async throws {
        let scope = WorkReference.Scope.local(installationID: "test")
        let wire = WorkCache.scope(for: scope)
        let folder = WorkSearchIndex.Folder(hostIdentity: "host", workspaceID: "folder")
        let cache = WorkSearchCache()
        let subscription = await cache.subscribe(scope: scope, folders: [folder])
        func reference(_ host: String) -> WorkReference {
            .init(scope: scope, hostIdentity: host, workspaceID: "folder", kind: .conversation, itemID: "chat")
        }
        func meta(_ host: String) -> CacheRecordMeta {
            .init(scope: wire, id: WorkCache.recordID(for: reference(host))!, kind: "conversation", itemId: "chat")
        }
        let transport = Transport()
        await transport.configure([meta("host"), meta("forbidden")])
        let loader = WorkSearchSavedLoader(cache: cache, subscription: subscription, scope: scope,
            folders: [folder: "Folder"], machines: ["host": "Computer"],
            list: { await transport.list($0) }, read: { try await transport.read($0, $1) })
        let first = try await loader.load()
        assert(first.eligible == 1 && first.indexed == 1 && first.unreadable == 0 && !first.interrupted)
        let reads = await transport.reads
        assert(reads == [meta("host").id])
        let query = try WorkSearchQuery("needle")
        let hits = try await subscription.index.search(query)
        assert(hits.total == 1)
        await transport.configure([meta("host")], failing: true)
        let failed = try await loader.load()
        let afterFailure = try await subscription.index.search(query)
        assert(failed.unreadable == 1 && afterFailure.total == 0)
        await transport.configure([meta("host")])
        _ = try await loader.load()
        await transport.configure([])
        let empty = try await loader.load()
        let deleted = try await subscription.index.search(query)
        assert(empty.eligible == 0 && deleted.total == 0)
        let mutation = await cache.beginMutation()
        let paused = try await loader.load()
        assert(paused.interrupted)
        await cache.finishMutation(mutation, scope: wire)
        await transport.configure([meta("host")])
        await transport.pauseNextRead()
        let canceled = Task { try await loader.load() }
        await transport.waitForRead()
        await loader.cancel()
        await transport.resumeRead()
        do {
            _ = try await canceled.value
            assertionFailure("Canceled read published")
        } catch is CancellationError {}
        let afterCancel = try await subscription.index.search(query)
        assert(afterCancel.total == 0)
        await transport.pauseNextRead()
        let superseded = Task { try await loader.load() }
        await transport.waitForRead()
        let current = try await loader.load()
        assert(current.indexed == 1)
        await transport.resumeRead()
        do {
            _ = try await superseded.value
            assertionFailure("Superseded read published")
        } catch is CancellationError {}
        let retainedCurrent = try await subscription.index.search(query)
        assert(retainedCurrent.total == 1)
        await transport.setLocked(true)
        do {
            _ = try await loader.load()
            assertionFailure("Locked cache reported ordinary coverage")
        } catch WorkSearchSavedLoader.Failure.locked {}
        let afterLock = try await subscription.index.search(query)
        assert(afterLock.total == 0)
        print("Saved search loader: pre-decrypt authorization, coverage, unreadable cleanup, listing reconciliation and mutation pause passed")
    }
}
