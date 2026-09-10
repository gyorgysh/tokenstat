// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Cache deletion waits for earlier writes to the same scope. A suspended
/// transport must not let an older write finish after a successful clear.
actor WorkCacheMutationQueue {
    static let shared = WorkCacheMutationQueue()
    private struct Pending { let id: UUID; let tail: Task<Void, Never> }
    private var pending: [String: Pending] = [:]
    private var generations: [String: UInt64] = [:]
    func generation(scope: String) -> UInt64 { generations[scope, default: 0] }

    func run<Value: Sendable>(scope: String, invalidating: Bool = false, expectedGeneration: UInt64? = nil, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if invalidating { generations[scope, default: 0] &+= 1 }
        let previous = pending[scope]?.tail
        let id = UUID()
        let job = Task {
            await previous?.value
            try Task.checkCancellation()
            if let expectedGeneration, self.generations[scope, default: 0] != expectedGeneration { throw CancellationError() }
            return try await operation()
        }
        pending[scope] = Pending(id: id, tail: Task { _ = try? await job.value })
        defer { if pending[scope]?.id == id { pending.removeValue(forKey: scope) } }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
