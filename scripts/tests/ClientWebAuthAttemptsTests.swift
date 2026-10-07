// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientWebAuthAttempts.swift.
import Foundation
@main struct Check {
    @MainActor static func main() {
        let attempts = ClientWebAuthAttempts()
        for _ in 0..<100 {
            let first = attempts.begin(), second = attempts.begin()
            precondition(!attempts.finish(first) && attempts.current == second)
            attempts.cancel()
            precondition(!attempts.finish(second) && attempts.current == nil)
            let next = attempts.begin()
            precondition(attempts.finish(next) && attempts.current == nil)
        }
        print("Auth callbacks cannot retire a newer attempt")
    }
}
