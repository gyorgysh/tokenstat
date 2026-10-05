// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum ChatFastMode {
    /// The host supplies supported model prefixes; nil also covers older
    /// hosts, which must not show a switch they cannot honor.
    static func available(model: String?, models: [String]?) -> Bool {
        guard let models else { return false }
        if models.isEmpty { return true }
        guard let model else { return false }
        let candidate = model.hasSuffix("[1m]") ? String(model.dropLast(4)) : model
        return models.contains { prefix in
            if candidate == prefix { return true }
            guard candidate.hasPrefix(prefix) else { return false }
            let suffix = String(candidate.dropFirst(prefix.count))
            guard suffix.hasPrefix("-") else { return false }
            let date = suffix.dropFirst()
            return date.count == 8 && date.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
}
