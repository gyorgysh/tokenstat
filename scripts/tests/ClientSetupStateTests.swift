// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientSetupState.swift. No account, network or credentials used.
import Foundation

@main
struct ClientSetupStateTests {
    static func main() throws {
        let a = String(repeating: "ab", count: 32)
        let b = String(repeating: "cd", count: 32)
        precondition(ClientSetupIdentity.normalize(" \(a.uppercased())\n") == a)
        precondition(ClientSetupIdentity.matches(a.uppercased(), expected: a))
        precondition(!ClientSetupIdentity.matches(b, expected: a), "A different host cannot satisfy setup")
        for bad in ["", "server", String(a.dropLast()), String(repeating: "z", count: 64)] {
            precondition(ClientSetupIdentity.normalize(bad) == nil)
            precondition(!ClientSetupIdentity.matches(bad, expected: bad))
        }
        print("ClientSetupStateTests passed")
    }
}
