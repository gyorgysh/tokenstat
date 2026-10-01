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
                return L10n.text("apple.automationqueuedraft.enter_a_positive_time_limit_or_choose_no_l.3b7996e8")
            }
        }
        let trimmed = maxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = UInt32(trimmed) else {
            return L10n.text("apple.automationqueuedraft.jobs_at_once_must_be_a_whole_number_or_no.a18bbfc5")
        }
        if count > Self.hostCap {
            return L10n.text("apple.automationqueuedraft.at_most_0_jobs_can_run_at_once.c6cd6b67", "\(Self.hostCap)")
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
            budget = L10n.text("apple.automationqueuedraft.no_time_limit.436b4b94")
        } else {
            let minutes = max(1, budgetSeconds / 60)
            switch minutes {
            case 15: budget = L10n.text("apple.automationqueuedraft.15m_per_job.518ce0c3")
            case 30: budget = L10n.text("apple.automationqueuedraft.30m_per_job.540c908c")
            case 60: budget = L10n.text("apple.automationqueuedraft.1h_per_job.d3a13f70")
            case 180: budget = L10n.text("apple.automationqueuedraft.3h_per_job.cabf928e")
            case 480: budget = L10n.text("apple.automationqueuedraft.8h_per_job.62ad336f")
            default: budget = L10n.text("apple.automationqueuedraft.0_min_per_job.60b07c42", "\(minutes)")
            }
        }
        let slots = maxConcurrent == 0 ? L10n.text("apple.automationqueuedraft.no_cap.59db2115") : L10n.text("apple.automationqueuedraft.0_at_once.4e557f9f", "\(maxConcurrent)")
        return "\(budget) · \(slots)"
    }
}
