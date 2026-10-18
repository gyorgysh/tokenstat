// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Disk caches and vendor responses arrive in different orders. Keep a
/// provider in the same seat through cached, loading and live readings.
enum PlanLimitsOrder {
    static func ordered<Value>(_ values: [Value], source: KeyPath<Value, String>) -> [Value] {
        let sources = ["codex", "claude_code", "cursor", "grok", "muse", "opencode", "antigravity"]
        return values.sorted {
            let left = $0[keyPath: source], right = $1[keyPath: source]
            let a = sources.firstIndex(of: left) ?? sources.count
            let b = sources.firstIndex(of: right) ?? sources.count
            return a == b ? left < right : a < b
        }
    }
}
