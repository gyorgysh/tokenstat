// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@MainActor final class ClientWebAuthAttempts {
    private(set) var current: UUID?
    func begin() -> UUID {
        let ticket = UUID()
        current = ticket
        return ticket
    }
    @discardableResult func finish(_ ticket: UUID) -> Bool {
        guard current == ticket else { return false }
        current = nil
        return true
    }
    func cancel() { current = nil }
}
