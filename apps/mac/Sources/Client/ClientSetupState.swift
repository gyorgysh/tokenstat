// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Public identity, not a mutable display name, binds provisioning to a peer.
enum ClientSetupIdentity {
    static func normalize(_ key: String) -> String? {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value.lowercased()
    }

    static func matches(_ actual: String, expected: String) -> Bool {
        guard let actual = normalize(actual), let expected = normalize(expected) else { return false }
        return actual == expected
    }
}
