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
        case .thisMachine: return "This device"
        case .allMachines: return "All devices"
        }
    }

    /// The glyph beside the label in the scope selector.
    var symbol: String {
        switch self {
        case .thisMachine: return "laptopcomputer"
        case .allMachines: return "network"
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
    /// True when the account grid fell back because signing in would fix it.
    ///
    /// The host says so with a structured code rather than a sentence, so the
    /// screen can offer a sign-in button instead of quoting a CLI command.
    private(set) var needsAccountSignIn = false

    /// What each vendor says is left of its plan.
    var planLimits: [ProviderLimits] = []
    var isLoadingLimits = false

    /// Archive-backed plan usage, by source. Separate from the vendor limits
    /// above: this is what the logs recorded, that is what the vendor reports.
    var planBySource: [Bucket] = []

    var isLoading = false
    /// Quiet re-read in progress (toolbar refresh, return to Home, post-scan).
    /// Does not flip `isLoading`, so wireframes do not replace drawn content.
    private(set) var isRefreshing = false
    var errorMessage: String?

    /// True after the heatmap (or a successful archive load) has landed once.
    ///
    /// RootView uses this to warm Machines / remotes / the launch catalog so
    /// the first click on those surfaces is a cache hit, not a cold host fan-out.
    /// Not the same as `!isLoading`: a failed load must not start the warm pass.
    private(set) var isArchiveReady = false

    private var hostRetryTask: Task<Void, Never>?
    private var hostRetryCount = 0
    /// When the archive was last successfully read. Used to skip redundant
    /// quiet refreshes when the user bounces between destinations.
    private var lastLoadedAt: Date?
    /// Minimum age before an automatic quiet refresh will hit the host again.
    private static let quietRefreshStale: TimeInterval = 45

    // MARK: - Day hover detail

    /// The day the pointer is over, by `YYYY-MM-DD`.
    private(set) var hoveredDay: String?
    /// The day's detail once it has answered, or nil while it loads.
    private(set) var hoveredDetail: DayDetail?
    private(set) var isLoadingDayDetail = false

    /// The day pinned in the inspector. Survives leaving Home and coming back.
    private(set) var selectedDay: HeatCell?
    private(set) var selectedDetail: DayDetail?
    private(set) var isLoadingSelectedDetail = false
    /// Insights-style breakdown for the pinned day. Local archive only.
    private(set) var selectedOverview: DayOverview?
    private(set) var isLoadingSelectedOverview = false

    /// Fetched details, kept per day so revisiting a cell is instant and a
    /// quick sweep across the grid does not re-ask for every cell.
    private var dayDetailCache: [String: DayDetail] = [:]
    private var dayDetailTask: Task<Void, Never>?
    private var dayOverviewCache: [String: DayOverview] = [:]
    private var dayOverviewTask: Task<Void, Never>?

    /// Value at list rates over the last seven calendar days, the same measure
    /// the heatmap colours by, so the two cannot disagree.
    var weekValue: Money {
        let micros = calendarDays.suffix(7).reduce(UInt64(0)) { $0 + $1.value }
        return Money(micros: Int64(micros), estimated: false, complete: true)
    }

    var todayValue: Money {
        let micros = calendarDays.last { $0.date == calendar?.last }?.value ?? 0
        return Money(micros: Int64(micros), estimated: false, complete: true)
    }

    /// Dated cells from the delivered grid, oldest first. The tiles read this
    /// rather than a second day report, so All devices and This device stay
    /// on the same series as the heatmap.
    private var calendarDays: [HeatCell] {
        guard let calendar else { return [] }
        return calendar.rows.flatMap { $0.compactMap { $0 } }.sorted { $0.date < $1.date }
    }

    /// Load archive-backed Home data.
    ///
    /// - Parameter quiet: when true (and content is already on screen), do not
    ///   set `isLoading`, so the heatmap stays put while numbers update. Used
    ///   for toolbar refresh, returning to Home, app activation, and post-scan.
    /// - Parameter refreshAccountGrid: drop the host's ten-minute series cache
    ///   so a pull after a plan change cannot redraw Free's locked year.
    func load(quiet: Bool = false, refreshAccountGrid: Bool = false) async {
        let soft = quiet && calendar != nil
        if soft {
            guard !isRefreshing, !isLoading else { return }
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }
        do {
            async let calendar = Bridge.activityCalendar(
                scope: scope.wire,
                force: refreshAccountGrid
            )
            // Plan usage still comes from the local archive. The iOS client
            // has none. `archiveOnly` turns that refusal into empty rather
            // than into an error banner over a heatmap that loaded well.
            async let plan = Self.archiveOnly {
                try await Bridge.report(group: .source, query: Query(billing: "plan"))
            }

            // Published one at a time, in the order the screen draws them,
            // rather than held back until all three have answered. The heatmap
            // is the largest thing on Home and the first query to return, so
            // waiting for the other two only kept it behind a blur for longer.
            let grid = try await calendar
            self.calendar = grid
            // Heatmap is the largest Home surface and the first query back.
            // Mark archive ready here (not after the other two) so secondary
            // screens can warm while day/plan reports still finish.
            isArchiveReady = true
            // What came back, not what was asked for.
            let newScope: ActivityScope = grid?.scope == "account" ? .allMachines : .thisMachine
            if newScope != deliveredScope {
                // The grid underneath the popover changed identity (e.g. an
                // account grid fell back to local). Stale day details would
                // describe a different machine's usage, so they have to go.
                dayDetailCache = [:]
                dayOverviewCache = [:]
                hoveredDay = nil
                hoveredDetail = nil
                isLoadingDayDetail = false
                dayDetailTask?.cancel()
                dayOverviewTask?.cancel()
                selectedOverview = nil
            }
            deliveredScope = newScope
            scopeNotice = grid?.notice
            needsAccountSignIn = grid?.noticeCode == "auth"

            self.planBySource = try await plan
            errorMessage = nil
            lastLoadedAt = Date()
            hostRetryCount = 0
            hostRetryTask?.cancel()
        } catch {
            // Host recovery is expected to resolve through the retry loop. The
            // footer reports it quietly, so Home does not replace useful data
            // with a large error card for a transient socket pause.
            if Bridge.isHostRecoveryError(error) {
                scheduleHostRetryIfNeeded(error)
                // Once the bounded retry budget is spent, the error belongs on
                // screen so the user has an explicit way to try again.
                errorMessage = hostRetryCount >= hostRetryLimit ? error.localizedDescription : nil
            } else {
                errorMessage = error.localizedDescription
                scheduleHostRetryIfNeeded(error)
            }
        }
    }

    /// Run a query that only a machine with a local archive can answer, and
    /// treat "there is no archive here" as an empty answer.
    ///
    /// The iOS client is that case: it has prices, a timezone and an account,
    /// and no store. Every other failure still throws, because a host that is
    /// down and a host that has nothing to read are not the same thing and must
    /// not render the same.
    private static func archiveOnly<T>(
        _ body: () async throws -> [T]
    ) async throws -> [T] {
        do {
            return try await body()
        } catch let BridgeError.core(code, _) where code == "no_local_archive" {
            return []
        }
    }

    /// Explicit re-read from the toolbar. Always hits the host; also refreshes
    /// plan limit cards so one control covers the whole Home surface.
    func refresh() async {
        await load(quiet: true, refreshAccountGrid: true)
        await loadPlanLimits()
    }

    /// Automatic re-read when the user comes back to Home or the app wakes.
    ///
    /// Skips if a load is already running, or the last successful load is
    /// fresher than `quietRefreshStale`, so bouncing the sidebar is free.
    func refreshIfStale() async {
        if let last = lastLoadedAt,
           Date().timeIntervalSince(last) < Self.quietRefreshStale
        {
            return
        }
        await load(quiet: true)
    }

    /// Keep trying while the host is still booting.
    ///
    /// The daemon can be down for a few seconds when the app opens ahead of
    /// it, and the first load failing then is nobody's fault. Instead of
    /// pinning an error banner the user would have to dismiss by hand, retry
    /// quietly in the background until the host answers or a bounded number
    /// of attempts runs out.
    private func scheduleHostRetryIfNeeded(_ error: Error) {
        guard Bridge.isHostRecoveryError(error), hostRetryCount < hostRetryLimit else {
            return
        }
        hostRetryCount += 1
        hostRetryTask?.cancel()
        hostRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    private let hostRetryLimit = 10

    /// The pointer moved over (or left) a heatmap cell.
    ///
    /// Keeps the hover state here rather than in the view so the popover can
    /// render above the whole window and still read the same truth. A quiet
    /// cell asks for nothing: the grid only lights priced days, and a day with
    /// no value has nothing to show.
    func hover(day: HeatCell?) {
        dayDetailTask?.cancel()
        guard let day, day.value > 0, !day.isLocked else {
            hoveredDay = nil
            hoveredDetail = nil
            isLoadingDayDetail = false
            return
        }

        hoveredDay = day.date
        if let cached = dayDetailCache[day.date] {
            hoveredDetail = cached
            isLoadingDayDetail = false
            return
        }

        isLoadingDayDetail = true
        hoveredDetail = nil
        fetchDayDetail(day.date, settle: true)
    }

    /// Pin a day in the inspector. Hover still only glances.
    func select(day: HeatCell) {
        selectedDay = day
        if day.isLocked {
            selectedDetail = nil
            selectedOverview = nil
            isLoadingSelectedDetail = false
            isLoadingSelectedOverview = false
            return
        }
        if let cached = dayDetailCache[day.date] {
            selectedDetail = cached
            isLoadingSelectedDetail = false
        } else {
            isLoadingSelectedDetail = true
            selectedDetail = nil
            fetchDayDetail(day.date, settle: false)
        }
        loadOverview(for: day.date)
    }

    /// Local reports for the pinned day: models, harnesses, projects, sessions.
    ///
    /// The account series has no project or session keys, so this stays off
    /// when the grid is counting every device.
    private func loadOverview(for date: String) {
        dayOverviewTask?.cancel()
        guard deliveredScope == .thisMachine else {
            selectedOverview = nil
            isLoadingSelectedOverview = false
            return
        }
        if let cached = dayOverviewCache[date] {
            selectedOverview = cached
            isLoadingSelectedOverview = false
            return
        }
        isLoadingSelectedOverview = true
        selectedOverview = nil
        dayOverviewTask = Task { [weak self] in
            let query = Query(since: date, until: date)
            var sessionQuery = query
            sessionQuery.limit = 80
            async let totalsResult = Bridge.totals(query)
            async let byModelResult = Bridge.report(group: .model, query: query)
            async let bySourceResult = Bridge.report(group: .source, query: query)
            async let byProjectResult = Bridge.report(group: .project, query: query)
            async let bySessionResult = Bridge.report(group: .session, query: sessionQuery)
            let overview = DayOverview(
                totals: try? await totalsResult,
                byModel: (try? await byModelResult) ?? [],
                bySource: (try? await bySourceResult) ?? [],
                byProject: (try? await byProjectResult) ?? [],
                bySession: (try? await bySessionResult) ?? []
            )
            guard !Task.isCancelled else { return }
            self?.finishOverview(date, overview)
        }
    }

    private func finishOverview(_ date: String, _ overview: DayOverview) {
        dayOverviewCache[date] = overview
        if selectedDay?.date == date {
            selectedOverview = overview
            isLoadingSelectedOverview = false
        }
    }

    private func fetchDayDetail(_ date: String, settle: Bool) {
        let scope = deliveredScope.wire
        dayDetailTask = Task { [weak self] in
            if settle {
                // A hover settle: crossing cells fast must not fire a request
                // per cell. 140ms is short enough to feel instant, long enough
                // to eat a sweep across the grid.
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }
            let detail = try? await Bridge.dayDetail(date: date, scope: scope)
            guard !Task.isCancelled else { return }
            self?.finishDayDetail(date, detail)
        }
    }

    private func finishDayDetail(_ date: String, _ detail: DayDetail?) {
        if let detail {
            dayDetailCache[date] = detail
        }
        if hoveredDay == date {
            hoveredDetail = detail
            isLoadingDayDetail = false
        }
        if selectedDay?.date == date {
            selectedDetail = detail
            isLoadingSelectedDetail = false
        }
    }

    /// Switch what the grid counts and redraw it.
    func setScope(_ new: ActivityScope) async {
        guard new != scope else { return }
        // The new grid is a different set of numbers; a cached hover from the
        // old one would describe the wrong scope.
        dayDetailCache = [:]
        dayOverviewCache = [:]
        hoveredDay = nil
        hoveredDetail = nil
        isLoadingDayDetail = false
        dayDetailTask?.cancel()
        dayOverviewTask?.cancel()
        selectedOverview = nil
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

/// Insights-shaped breakdown for one local day.
struct DayOverview: Sendable {
    var totals: Totals?
    var byModel: [Bucket]
    var bySource: [Bucket]
    var byProject: [Bucket]
    var bySession: [Bucket]
}
