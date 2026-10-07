// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatReadKey: Hashable, Sendable {
    let owner: Data
    let peer: String?
    let method: String
    let parameters: Data
    let patience: TimeInterval
}

/// Shares only simultaneous reads. Completed values are never cached, and
/// mutations invalidate both predecessor results and their sharing slots.
actor ChatReadFlights {
    static let reads: Set<String> = ["chat.list", "chat.recent", "chat.events", "chat.eventPage",
                                     "chat.approvals", "chat.instructions", "chat.personas"]
    static let mutations: Set<String> = ["chat.create", "chat.fork", "chat.update", "chat.remove", "chat.removeAll",
        "chat.send", "chat.stop", "chat.answerQuestion", "chat.steer", "chat.steerClear", "chat.steerDeliver",
        "chat.resolveApproval", "chat.personaSave", "chat.personaDefault", "chat.personaRemove"]
    private struct Domain: Hashable { let owner: Data; let peer: String? }
    private struct TypedKey: Hashable { let request: ChatReadKey; let type: String }
    private struct Entry: Sendable { let token: UUID; let task: any Sendable }
    private var entries: [TypedKey: Entry] = [:]
    private var revisions: [Domain: UInt64] = [:]

    func run<Value: Sendable>(_ key: ChatReadKey,
                             operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !Task.isCancelled else { throw CancellationError() }
        let typed = TypedKey(request: key, type: String(reflecting: Value.self))
        let domain = Domain(owner: key.owner, peer: key.peer)
        while true {
            guard !Task.isCancelled else { throw CancellationError() }
            let revision = revisions[domain, default: 0]
            let token: UUID, task: Task<Value, Error>
            if let existing = entries[typed], let shared = existing.task as? Task<Value, Error> {
                token = existing.token; task = shared
            } else {
                token = UUID(); task = Task { try await operation() }
                entries[typed] = Entry(token: token, task: task)
            }
            // Cancellation belongs to the waiter, not the shared producer.
            // Validate both result branches before using either one.
            let result = await task.result
            if entries[typed]?.token == token { entries.removeValue(forKey: typed) }
            guard !Task.isCancelled else { throw CancellationError() }
            guard revisions[domain, default: 0] == revision else {
                // A normal mutation must not look like a transport failure
                // to a live reader or trigger its whole-history fallback.
                continue
            }
            return try result.get()
        }
    }

    func invalidate(owner: Data, peer: String?) {
        let domain = Domain(owner: owner, peer: peer)
        revisions[domain, default: 0] &+= 1
        entries = entries.filter { $0.key.request.owner != owner || $0.key.request.peer != peer }
        // Do not cancel a dispatched read: other transport users may own it.
        // Its captured revision prevents a late answer being used here.
    }
}
