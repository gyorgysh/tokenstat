// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

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
