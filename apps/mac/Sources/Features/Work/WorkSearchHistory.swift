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
    private final class WeakHistory { weak var value: WorkSearchHistory?; init(_ value: WorkSearchHistory) { self.value = value } }
    private static var instances: [WorkReference.Scope: WeakHistory] = [:]
    static func shared(for scope: WorkReference.Scope) -> WorkSearchHistory {
        instances = instances.filter { $0.value.value != nil }
        if let existing = instances[scope]?.value, !existing.invalidated { return existing }
        let history = WorkSearchHistory(scope: scope)
        instances[scope] = WeakHistory(history)
        return history
    }
    static func invalidate(except scope: WorkReference.Scope?) {
        for (owner, weakHistory) in instances where owner != scope {
            guard let history = weakHistory.value else { continue }
            history.invalidated = true
            history.epoch &+= 1
            history.payload = Payload()
            history.failure = nil
        }
    }
    static func forgetCached(scope: String) async {
        for weakHistory in instances.values {
            guard let history = weakHistory.value, history.wireScope == scope else { continue }
            history.epoch &+= 1
            history.payload = Payload()
            history.failure = nil
            await history.tail?.value
        }
    }
    private var invalidated = false
    private var epoch: UInt64 = 0
    private var tail: Task<Void, Never>?
    private var pending = 0
    var busy: Bool { pending > 0 }
    private func ordered(_ action: @escaping @MainActor () async -> Void) async {
        let previous = tail
        pending += 1
        let task = Task { await previous?.value; await action() }
        tail = task
        await task.value
        pending -= 1
        if pending == 0 { tail = nil }
    }
    private let scope: WorkReference.Scope
    private let wireScope: String
    private let preference: String
    private(set) var enabled: Bool
    private(set) var payload = Payload()
    private(set) var failure: String?

    init(scope: WorkReference.Scope) {
        self.scope = scope
        wireScope = WorkCache.scope(for: scope)
        preference = "work.search.history.enabled." + WorkCache.scope(for: scope)
        enabled = UserDefaults.standard.bool(forKey: preference)
    }
    private var current: Bool { !invalidated && WorkSessionContext.shared.readingScope == scope }

    func load() async {
        let requestedEpoch = epoch
        await ordered { [self] in
            guard current, enabled, epoch == requestedEpoch else { return }
            guard let key = WorkCacheKey.existingKey(for: wireScope) else { return }
            do {
                let stored = try await Bridge.searchHistory(key: WorkCacheKey.encoded(key), scope: wireScope)
                guard current, epoch == requestedEpoch, enabled else { payload = Payload(); return }
                payload = bounded(stored ?? Payload())
                failure = nil
            } catch { if current, epoch == requestedEpoch { failure = "Search history could not be opened. Try again after unlocking this device." } }
        }
    }

    func setEnabled(_ value: Bool) async {
        guard current else { return }
        enabled = value
        UserDefaults.standard.set(value, forKey: preference)
        if value { await load() }
        else {
            payload = Payload()
            await clear()
        }
    }

    func clear() async {
        epoch &+= 1
        payload = Payload()
        let requestedEpoch = epoch
        await ordered { [self] in
            guard current, epoch == requestedEpoch else { return }
            do {
                _ = try await Bridge.cacheRemove(scope: wireScope, id: "search-history-v1")
                payload = Payload()
                failure = nil
            } catch { if current, epoch == requestedEpoch { failure = "History could not be cleared. Try again." } }
        }
    }

    func remember(query: String, destination: Destination? = nil) async {
        let requestedEpoch = epoch
        await ordered { [self] in
            guard current, enabled, epoch == requestedEpoch else { return }
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = try? WorkSearchQuery(query), !parsed.terms.isEmpty || destination != nil else { return }
            let availableKey = WorkCacheKey.existingKey(for: wireScope)
                ?? (WorkSessionContext.shared.scope == scope ? WorkCacheKey.key(for: wireScope) : nil)
            guard let key = availableKey else {
                failure = "Unlock this device to save search history."
                return
            }
            var next = payload
            if !parsed.terms.isEmpty {
                next.queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
                next.queries.insert(query, at: 0)
            }
            if let destination, destination.reference.scope == scope, WorkCacheAccess.canRead(destination.reference) {
                next.destinations.removeAll { $0.reference == destination.reference }
                next.destinations.insert(destination, at: 0)
            }
            next = bounded(next)
            do {
                guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any] else {
                    throw WorkCacheError.encoding
                }
                _ = try await Bridge.cachePut(key: WorkCacheKey.encoded(key), scope: wireScope,
                    id: "search-history-v1", kind: "searchHistory", itemId: "search-history-v1",
                    revision: "1", payload: object)
                guard current, epoch == requestedEpoch, enabled else { payload = Payload(); return }
                payload = next
                failure = nil
            } catch { if current, epoch == requestedEpoch { failure = "History could not be saved. Your search is still available." } }
        }
    }

    private func bounded(_ value: Payload) -> Payload {
        Payload(queries: Array(value.queries.filter { query in
            guard let parsed = try? WorkSearchQuery(query) else { return false }
            return !parsed.terms.isEmpty
        }.prefix(12)), destinations: Array(value.destinations.filter {
            $0.reference.scope == scope && WorkCacheAccess.canRead($0.reference) && !$0.title.isEmpty && $0.title.utf8.count <= 4096
        }.prefix(12)))
    }
}
