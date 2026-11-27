// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

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
