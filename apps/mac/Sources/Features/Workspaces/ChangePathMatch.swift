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
    /// Preserve a valid selection; otherwise resolve a requested path or use
    /// the first file. Review navigation never changes the commit selection.
    static func reviewSelection(_ selected: String?, focus: String?, paths: [String]) -> String? {
        if let selected, paths.contains(selected) { return selected }
        if let focus, let matched = path(focus, in: paths) { return matched }
        return paths.first
    }
}
