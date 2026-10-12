// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A removal must reach the server after any registration already in flight.
/// Cancellation alone cannot undo a request the server has already accepted.
@MainActor final class PushRegistrationQueue {
    private var pending: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = pending
        let task = Task {
            await previous?.value
            await operation()
        }
        pending = task
        return task
    }
}
