// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Preserve terminal byte order across asynchronous bridge requests.
@MainActor
final class SSHInputQueue {
    private var tail: Task<Bool, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = tail
        let next = Task {
            _ = await previous?.value
            return await operation()
        }
        tail = next
        return next
    }
}
