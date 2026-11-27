// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

@MainActor
final class Singleflight<Value: Sendable> {
    private var inFlight: Task<Value, Never>?

    var isRunning: Bool { inFlight != nil }

    func run(_ operation: @MainActor @Sendable @escaping () async -> Value) async -> Value {
        if let running = inFlight {
            return await running.value
        }
        let task = Task { @MainActor in await operation() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        return value
    }
}
