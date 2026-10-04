// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChangePathMatch {
    /// Git uses repository-relative paths. Agents may use absolute paths or
    /// Windows separators. Prefer the most specific match when names overlap.
    static func path(_ requested: String, in paths: [String]) -> String? {
        let wanted = requested.replacingOccurrences(of: "\\", with: "/")
        return paths.sorted { $0.count > $1.count }.first { path in
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            return wanted == normalized || wanted.hasSuffix("/" + normalized)
        }
    }
}
