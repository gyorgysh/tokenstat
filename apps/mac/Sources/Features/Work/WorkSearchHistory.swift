// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Optional history shares saved work's encryption, expiry and scope cleanup.
/// Preferences contain only consent; query text and destination labels are sealed.
@MainActor @Observable
final class WorkSearchHistory {
    struct Destination: Codable, Identifiable, Sendable {
        let reference: WorkReference
        let title: String
        var id: WorkReference { reference }
    }
    struct Payload: Codable, Sendable {
        var queries: [String] = []
        var destinations: [Destination] = []
    }
    private let scope: WorkReference.Scope
    private let wireScope: String
    private let preference: String
    private(set) var enabled: Bool
    private(set) var payload = Payload()
    private(set) var busy = false
    private(set) var failure: String?

    init(scope: WorkReference.Scope) {
        self.scope = scope
        wireScope = WorkCache.scope(for: scope)
        preference = "work.search.history.enabled." + WorkCache.scope(for: scope)
        enabled = UserDefaults.standard.bool(forKey: preference)
    }
    private var current: Bool { WorkSessionContext.shared.readingScope == scope }

    func load() async {
        guard current, enabled, !busy else { return }
        guard let key = WorkCacheKey.existingKey(for: wireScope) else { return }
        busy = true
        defer { busy = false }
        do {
            let stored = try await Bridge.searchHistory(key: WorkCacheKey.encoded(key), scope: wireScope)
            guard current else { payload = Payload(); return }
            payload = bounded(stored ?? Payload())
            failure = nil
        } catch { if current { failure = "Search history could not be opened. Try again after unlocking this device." } }
    }

    func setEnabled(_ value: Bool) async {
        guard current, !busy else { return }
        enabled = value
        UserDefaults.standard.set(value, forKey: preference)
        if value { await load() }
        else {
            payload = Payload()
            await clear()
        }
    }

    func clear() async {
        guard current, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await Bridge.cacheRemove(scope: wireScope, id: "search-history-v1")
            payload = Payload()
            failure = nil
        } catch { if current { failure = "History could not be cleared. Try again." } }
    }

    func remember(query: String, destination: Destination? = nil) async {
        guard current, enabled, !busy else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? WorkSearchQuery(query), !parsed.terms.isEmpty || destination != nil else { return }
        guard let key = WorkCacheKey.key(for: wireScope) else {
            failure = "Unlock this device to save search history."
            return
        }
        var next = payload
        if !parsed.terms.isEmpty {
            next.queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
            next.queries.insert(query, at: 0)
        }
        if let destination, destination.reference.scope == scope {
            next.destinations.removeAll { $0.reference == destination.reference }
            next.destinations.insert(destination, at: 0)
        }
        next = bounded(next)
        busy = true
        defer { busy = false }
        do {
            guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any] else {
                throw WorkCacheError.encoding
            }
            _ = try await Bridge.cachePut(key: WorkCacheKey.encoded(key), scope: wireScope,
                id: "search-history-v1", kind: "searchHistory", itemId: "search-history-v1",
                revision: "1", payload: object)
            guard current else { payload = Payload(); return }
            payload = next
            failure = nil
        } catch { if current { failure = "History could not be saved. Your search is still available." } }
    }

    private func bounded(_ value: Payload) -> Payload {
        Payload(queries: Array(value.queries.filter { query in
            guard let parsed = try? WorkSearchQuery(query) else { return false }
            return !parsed.terms.isEmpty
        }.prefix(12)), destinations: Array(value.destinations.filter {
            $0.reference.scope == scope && !$0.title.isEmpty && $0.title.utf8.count <= 4096
        }.prefix(12)))
    }
}
