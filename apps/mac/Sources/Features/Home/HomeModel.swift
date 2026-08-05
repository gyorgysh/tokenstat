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
/// Which machines the activity grid counts.
///
/// The local archive is one machine's logs, which is the whole design: the
/// parser reads what is on this disk. "What have I spent everywhere" is a
/// different question, and the account the machines already upload to is the
/// only thing that can answer it.
enum ActivityScope: String, CaseIterable, Identifiable, Sendable {
    case thisMachine
    case allMachines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMachine: return "This machine"
        case .allMachines: return "All machines"
        }
    }

    /// What the host calls it.
    var wire: String {
        switch self {
        case .thisMachine: return "local"
        case .allMachines: return "account"
        }
    }
}

@Observable
@MainActor
final class HomeModel {
    private(set) var calendar: ActivityCalendar?

    /// What the user asked the grid to count. Every machine by default: a
    /// person with two Macs wants their year, not one laptop's share of it.
    var scope: ActivityScope = .allMachines

    /// What the host actually built.
    ///
    /// Not the same as `scope`. An account grid needs the network and an
    /// account, and when it cannot be had the host falls back to this machine's
    /// own archive. Drawing that as the account's would report one laptop's
    /// spend as everybody's, so the two are kept apart.
    private(set) var deliveredScope: ActivityScope = .thisMachine

    /// Why the grid on screen is not the one that was asked for.
    private(set) var scopeNotice: String?
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

    /// Value at list rates over the last seven calendar days, the same measure
    /// the heatmap colours by, so the two cannot disagree.
    var weekValue: Money {
        week.totalValue
    }

    var todayValue: Money {
        today.map { [$0].totalValue } ?? Money(micros: 0, estimated: false, complete: true)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let calendar = Bridge.activityCalendar(scope: scope.wire)
            async let daily = Bridge.report(group: .day, query: Query())
            async let plan = Bridge.report(group: .source, query: Query(billing: "plan"))

            // Published one at a time, in the order the screen draws them,
            // rather than held back until all three have answered. The heatmap
            // is the largest thing on Home and the first query to return, so
            // waiting for the other two only kept it behind a blur for longer.
            let grid = try await calendar
            self.calendar = grid
            // What came back, not what was asked for.
            deliveredScope = grid?.scope == "account" ? .allMachines : .thisMachine
            scopeNotice = grid?.notice

            let days = try await daily

            // The archive returns days oldest first. The last seven rows are
            // the last seven days *with data*, which is not the same as the
            // last seven days, so the range is taken from the calendar's own
            // anchor instead.
            let anchor = grid?.last ?? days.last?.key ?? ""
            self.today = days.last { $0.key == anchor }
            self.week = Array(days.suffix(7))

            self.planBySource = try await plan
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Switch what the grid counts and redraw it.
    func setScope(_ new: ActivityScope) async {
        guard new != scope else { return }
        scope = new
        await load()
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
