// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Server-owned counters. Calendar-month usage is informational, never a reset.
struct RelayUsage: Codable, Sendable, Hashable {
    var policy: String
    var windowDays: Int
    var timezone: String
    var asOf: String
    var reportingDelaySeconds: Int
    var windowStart: String
    var windowEnd: String
    var limitBytes: UInt64
    var usedBytes: UInt64
    var remainingBytes: UInt64
    var todayBytes: UInt64
    var monthBytes: UInt64
    var nextUnlockAt: String?
    var nextUnlockBytes: UInt64
    var daily: [RelayUsageDay]

    var isSupported: Bool {
        policy == "rolling_30_utc_days" && windowDays == 30 && timezone == "UTC"
    }

    var fraction: Double {
        limitBytes > 0 ? min(1, Double(usedBytes) / Double(limitBytes)) : 0
    }

    var usedDays: [RelayUsageDay] {
        daily.filter { $0.bytes > 0 }
    }

    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(clamping: value))
    }
}

struct RelayUsageDay: Codable, Sendable, Hashable, Identifiable {
    var day: String
    var bytes: UInt64
    var id: String { day }
}
