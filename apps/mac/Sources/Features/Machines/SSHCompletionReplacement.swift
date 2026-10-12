// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A completion can replace only the fragment for which it was offered.
enum SSHCompletionReplacement {
    static func count(replacing: Int, fragment: String, current: String) -> Int? {
        guard replacing >= 0, replacing <= fragment.count, current.hasPrefix(fragment) else { return nil }
        return replacing + (current.count - fragment.count)
    }
}
