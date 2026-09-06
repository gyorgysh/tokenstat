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

    /// Binary units, spelled the way the plan copy spells them.
    ///
    /// `ByteCountFormatter` with `.binary` divides by 1024 and then labels the
    /// answer GB, so a card sitting under a paywall promising "20 GiB" read
    /// "20 GB", and the Windows and Android cards for the same number said
    /// GiB. It is localized too, so the unit moved again on a French device.
    static func bytes(_ value: UInt64) -> String {
        let kibi = 1024.0
        let amount = Double(value)
        func scaled(_ divisor: Double, _ unit: String) -> String {
            let shown = amount / divisor
            let digits = shown >= 10 ? 0 : 1
            return "\(shown.formatted(.number.precision(.fractionLength(0...digits)))) \(unit)"
        }
        if amount >= kibi * kibi * kibi { return scaled(kibi * kibi * kibi, "GiB") }
        if amount >= kibi * kibi { return scaled(kibi * kibi, "MiB") }
        if amount >= kibi { return scaled(kibi, "KiB") }
        return "\(value) B"
    }
}

struct RelayUsageDay: Codable, Sendable, Hashable, Identifiable {
    var day: String
    var bytes: UInt64
    var id: String { day }
}
