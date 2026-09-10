// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkCache.swift WorkCacheStore.swift WorkCacheModels.swift.
import Foundation

// Local transport/keychain doubles. No production credentials or files are used.
struct ChatEventPage: Codable, Sendable {
    struct Event: Codable, Sendable { var seq: UInt64?; var text: String }
    var events: [Event]
    var nextOffset: UInt64
    var hasEarlier: Bool
}
enum WorkCacheAccess {
    static func canSave(_ reference: WorkReference) async -> Bool { true }
    static func canRead(_ reference: WorkReference) async -> Bool { true }
}
enum BridgeError: Error { case core(code: String, message: String) }
enum WorkCacheKey {
    static var keys: [String: [UInt8]] = [:]
    static func key(for scope: String) -> [UInt8]? {
        if let key = keys[scope] { return key }
        let key = [UInt8](repeating: UInt8(keys.count + 1), count: 32)
        keys[scope] = key
        return key
    }
    static func existingKey(for scope: String) -> [UInt8]? { keys[scope] }
    static func encoded(_ key: [UInt8]) -> String { Data(key).base64EncodedString() }
}
enum Bridge {
    static var records: [String: (key: String, data: Data)] = [:]
    static var writes = 0
    static var reads = 0
    static func cachePut(key: String, scope: String, id: String, kind: String,
                         itemId: String, revision: String, payload: [String: Any]) async throws {
        writes += 1
        records[scope + "/" + id] = (key, try JSONSerialization.data(withJSONObject: payload))
    }
    struct Record {
        let scope: String; let id: String; let kind = "conversation"; let itemId: String
        let payload: CachedRecordPayload
    }
    static func cacheGet(key: String, scope: String, id: String) async throws -> Record {
        reads += 1
        guard let saved = records[scope + "/" + id], saved.key == key else {
            throw BridgeError.core(code: "missing", message: "No saved copy")
        }
        let decoder = JSONDecoder()
        // Match Bridge.background's ordinary JSONDecoder, without a date override.
        return Record(scope: scope, id: id, itemId: String(id.split(separator: "|").last ?? "").removingPercentEncoding ?? "",
                      payload: try decoder.decode(CachedRecordPayload.self, from: saved.data))
    }
    static func cacheRemove(scope: String, id: String) async throws {
        records.removeValue(forKey: scope + "/" + id)
    }
    static func cachePin(scope: String, id: String, pinned: Bool) async throws {}
}

@main struct WorkCacheStoreTests {
    static func main() async {
        let suite = "WorkCacheStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkCacheSettings(defaults: defaults)
        let store = WorkCacheStore(settings: settings)
        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!
        func ref(_ scope: WorkReference.Scope = alice, host: String = "host-a") -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: "folder", kind: .conversation, itemID: "chat")
        }
        let page = ChatEventPage(events: [.init(seq: 1, text: "Saved words")], nextOffset: 42, hasEarlier: true)
        await store.saveConversation(reference: ref(), title: "My work", page: page, backend: "codex")
        assert(Bridge.writes == 1)
        settings.enabled = false
        await store.saveConversation(reference: ref(), title: "Replacement", page: page)
        assert(Bridge.writes == 1)
        // Turning saving off preserves access to previously kept text.
        let saved = await store.savedConversation(for: ref())
        assert(saved?.title == "My work" && saved?.backend == "codex")
        assert(saved?.page.events.first?.text == "Saved words" && saved?.page.hasEarlier == true)
        let keysBefore = WorkCacheKey.keys.count
        let absentAccount = await store.savedConversation(for: ref(bob))
        assert(absentAccount == nil && WorkCacheKey.keys.count == keysBefore)
        let absentHost = await store.savedConversation(for: ref(host: "host-b"))
        assert(absentHost == nil)
        // Old envelopes with no backend still open; an empty page is a copy.
        settings.enabled = true
        await store.saveConversation(reference: ref(), title: "Empty", page: .init(events: [], nextOffset: 0, hasEarlier: false))
        let old = await store.savedConversation(for: ref())
        assert(old?.backend == nil && old?.page.events.isEmpty == true)
        // The production bridge does not install a custom Date strategy.
        // A malformed saved timestamp must fail rather than claim a fresh copy.
        let malformed = Data(#"{"title":"x","revision":"r","savedAt":"bad","page":{"events":[],"nextOffset":0,"hasEarlier":false}}"#.utf8)
        assert((try? JSONDecoder().decode(CachedRecordPayload.self, from: malformed)) == nil)
        // Corruption and unavailable keys fail closed rather than inventing rows.
        let storageKey = WorkCache.scope(for: alice) + "/" + WorkCache.recordID(for: ref())!
        Bridge.records[storageKey]!.data = Data("corrupt".utf8)
        let corrupt = await store.savedConversation(for: ref())
        assert(corrupt == nil)
        WorkCacheKey.keys = [:]
        let readsBefore = Bridge.reads
        let locked = await store.savedConversation(for: ref())
        assert(locked == nil && Bridge.reads == readsBefore)
        print("Work cache store: retained copies, metadata compatibility, empty pages, scope isolation and corruption passed")
    }
}
