// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkSearchText.swift WorkSearchHistory.swift.
import Foundation
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var readingScope: WorkReference.Scope? { scope }
}
enum WorkCache { static func scope(for scope: WorkReference.Scope) -> String { scope.identity } }
enum WorkCacheAccess { static func canRead(_ reference: WorkReference) -> Bool { true } }
enum WorkCacheError: Error { case encoding }
enum WorkCacheKey {
    static func key(for scope: String) -> String? { scope }
    static func existingKey(for scope: String) -> String? { scope }
    static func encoded(_ key: String) -> String { key }
}
@MainActor enum Bridge {
    static var stored: WorkSearchHistory.Payload?
    static var paused = false
    static var started = false
    static var waiter: CheckedContinuation<Void, Never>?
    static var resumed: CheckedContinuation<Void, Never>?
    static func searchHistory(key: String, scope: String) async throws -> WorkSearchHistory.Payload? { stored }
    static func cacheRemove(scope: String, id: String) async throws { stored = nil }
    static func cachePut(key: String, scope: String, id: String, kind: String, itemId: String, revision: String, payload: [String: Any]) async throws {
        if paused {
            started = true
            waiter?.resume(); waiter = nil
            await withCheckedContinuation { resumed = $0 }
        }
        stored = try JSONDecoder().decode(WorkSearchHistory.Payload.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    static func waitForWrite() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    static func release() { paused = false; started = false; resumed?.resume(); resumed = nil }
}
@main struct WorkSearchHistoryTests {
    @MainActor static func main() async {
        let scope = WorkReference.Scope.local(installationID: "history-test-" + UUID().uuidString)
        let preference = "work.search.history.enabled." + WorkCache.scope(for: scope)
        defer { UserDefaults.standard.removeObject(forKey: preference) }
        WorkSessionContext.shared.scope = scope
        let first = WorkSearchHistory.shared(for: scope)
        let second = WorkSearchHistory.shared(for: scope)
        assert(first === second, "All windows of one account use one ordered history")
        assert(!first.enabled)
        await first.setEnabled(true)
        Bridge.paused = true
        let one = Task { await first.remember(query: "first query") }
        await Bridge.waitForWrite()
        let two = Task { await second.remember(query: "second query") }
        Bridge.release()
        await one.value; await two.value
        assert(Set(first.payload.queries) == Set(["first query", "second query"]))
        assert(Set(Bridge.stored!.queries) == Set(first.payload.queries))
        Bridge.paused = true
        let pending = Task { await first.remember(query: "clear this pending query") }
        await Bridge.waitForWrite()
        let release = Task { Bridge.release() }
        await second.clear()
        await release.value; await pending.value
        assert(first.payload.queries.isEmpty && Bridge.stored == nil)
        await first.remember(query: "kept until sign out")
        assert(first.payload.queries == ["kept until sign out"])
        assert(Bridge.stored?.queries == ["kept until sign out"], "New searches must not restore history cleared from another window")
        WorkSearchHistory.invalidate(except: nil)
        assert(first.payload.queries.isEmpty)
        await first.remember(query: "stale window")
        assert(first.payload.queries.isEmpty)
        let replacement = WorkSearchHistory.shared(for: scope)
        assert(replacement !== first)
        await replacement.setEnabled(false)
        assert(Bridge.stored == nil && !replacement.enabled)
        print("Search history: shared windows, ordered remembers, clear after suspended write, sign-out invalidation and opt-out passed")
    }
}
