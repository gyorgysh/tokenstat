// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Dismissal survives refreshes and restarts. Settings remains the retry path.
struct UsageKeychainNoticePolicy {
    private(set) var dismissed: Set<String>

    init(saved: String) {
        dismissed = Set(saved.split(separator: ",").map(String.init))
    }

    func offer(affected: [String]) -> String? {
        affected.first { ["claude_code", "muse"].contains($0) && !dismissed.contains($0) }
    }

    mutating func dismiss(affected: [String]) {
        dismissed.formUnion(affected.filter { ["claude_code", "muse"].contains($0) })
    }

    var saved: String { dismissed.sorted().joined(separator: ",") }
}
