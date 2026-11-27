// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChangePathMatch {
    static func path(_ requested: String, in paths: [String]) -> String? {
        let wanted = requested.replacingOccurrences(of: "\\", with: "/")
        return paths.sorted { $0.count > $1.count }.first { path in
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            return wanted == normalized || wanted.hasSuffix("/" + normalized)
        }
    }
    static func reviewSelection(_ selected: String?, focus: String?, paths: [String]) -> String? {
        if let selected, paths.contains(selected) { return selected }
        if let focus, let matched = path(focus, in: paths) { return matched }
        return paths.first
    }
}
