// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation

/// Host-wide scheduler defaults: how long a new job may run, and how many
/// may run at once. This is not a folder setting.
struct AutomationQueueDraft: Equatable, Sendable {
    static let hostCap: UInt32 = 32

    var budgetMinutes: String
    var noLimit: Bool
    var maxConcurrent: String

    init(
        budgetMinutes: String = "180",
        noLimit: Bool = false,
        maxConcurrent: String = "2"
    ) {
        self.budgetMinutes = budgetMinutes
        self.noLimit = noLimit
        self.maxConcurrent = maxConcurrent
    }

    init(_ queue: AutomationQueue) {
        noLimit = queue.defaultBudgetSeconds == 0
        budgetMinutes = noLimit ? "180" : String(max(1, queue.defaultBudgetSeconds / 60))
        maxConcurrent = String(queue.maxConcurrent)
    }

    var validation: String? {
        if !noLimit {
            let trimmed = budgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let minutes = UInt64(trimmed), minutes > 0, minutes <= UInt64.max / 60 else {
                return "Enter a positive time limit, or choose No limit."
            }
        }
        let trimmed = maxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = UInt32(trimmed) else {
            return "Jobs at once must be a whole number, or No cap."
        }
        if count > Self.hostCap {
            return "At most \(Self.hostCap) jobs can run at once."
        }
        return nil
    }

    var budgetSeconds: UInt64? {
        if noLimit { return 0 }
        let trimmed = budgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = UInt64(trimmed), minutes > 0, minutes <= UInt64.max / 60 else {
            return nil
        }
        return minutes * 60
    }

    var concurrent: UInt32? {
        let trimmed = maxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = UInt32(trimmed), count <= Self.hostCap else { return nil }
        return count
    }

    var isBudgetPreset: Bool {
        let presets = [15, 30, 60, 180, 480]
        return !noLimit && presets.contains(Int(budgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)
    }

    var isConcurrentPreset: Bool {
        let presets: [UInt32] = [0, 1, 2, 4, 8]
        guard let count = UInt32(maxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return presets.contains(count)
    }

    func matches(_ queue: AutomationQueue) -> Bool {
        guard let budget = budgetSeconds, let count = concurrent else { return false }
        return budget == queue.defaultBudgetSeconds && count == queue.maxConcurrent
    }

    /// One line for the library card. Uses the chip names when they match.
    static func summary(budgetSeconds: UInt64, maxConcurrent: UInt32) -> String {
        let budget: String
        if budgetSeconds == 0 {
            budget = "No time limit"
        } else {
            let minutes = max(1, budgetSeconds / 60)
            switch minutes {
            case 15: budget = "15m per job"
            case 30: budget = "30m per job"
            case 60: budget = "1h per job"
            case 180: budget = "3h per job"
            case 480: budget = "8h per job"
            default: budget = "\(minutes) min per job"
            }
        }
        let slots = maxConcurrent == 0 ? "No cap" : "\(maxConcurrent) at once"
        return "\(budget) · \(slots)"
    }
}
