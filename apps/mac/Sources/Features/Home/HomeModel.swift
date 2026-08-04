// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// What the Home screen shows.
///
/// Home answers "what do I have left before I start", which is a different
/// question from "what did I spend last month". Insights answers the second.
/// Keeping them apart is why the plan limit cards moved here: they were the
/// first thing on the reporting screen and the last thing a reporting screen
/// should be about.
@Observable
@MainActor
final class HomeModel {
    private(set) var calendar: ActivityCalendar?
    private(set) var today: Bucket?
    private(set) var week: [Bucket] = []

    /// What each vendor says is left of its plan.
    var planLimits: [ProviderLimits] = []
    var isLoadingLimits = false

    /// Archive-backed plan usage, by source. Separate from the vendor limits
    /// above: this is what the logs recorded, that is what the vendor reports.
    var planBySource: [Bucket] = []

    var isLoading = false
    var errorMessage: String?

    /// Tokens in the last seven calendar days, cache excluded, matching the
    /// heatmap's own measure so the two cannot disagree.
    var weekTotal: UInt64 {
        week.reduce(0) { $0 + $1.counters.workTokens }
    }

    var todayTotal: UInt64 {
        today?.counters.workTokens ?? 0
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let calendar = Bridge.activityCalendar()
            async let daily = Bridge.report(group: .day, query: Query())
            async let plan = Bridge.report(group: .source, query: Query(billing: "plan"))

            let grid = try await calendar
            let days = try await daily
            self.calendar = grid
            self.planBySource = try await plan

            // The archive returns days oldest first. The last seven rows are
            // the last seven days *with data*, which is not the same as the
            // last seven days, so the range is taken from the calendar's own
            // anchor instead.
            let anchor = grid?.last ?? days.last?.key ?? ""
            self.today = days.last { $0.key == anchor }
            self.week = Array(days.suffix(7))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Vendor plan limits, loaded on their own.
    ///
    /// Never with the archive: one of these providers is a network call, and
    /// the archive reloads on every period change on the other screen.
    func loadPlanLimits() async {
        isLoadingLimits = true
        defer { isLoadingLimits = false }
        planLimits = (try? await Bridge.usageLimits()) ?? []
    }
}
