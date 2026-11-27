// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

enum ActivityScope: String, CaseIterable, Identifiable, Sendable {
    case thisMachine
    case allMachines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMachine: return L10n.text("apple.homemodel.this_device.d052579c")
        case .allMachines: return L10n.text("apple.homemodel.all_devices.0594fe82")
        }
    }

    var symbol: String {
        switch self {
        case .thisMachine: return "laptopcomputer"
        case .allMachines: return "network"
        }
    }

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

    var scope: ActivityScope = ActivityScope(rawValue: UserDefaults.standard.string(forKey: "activity.scope") ?? "") ?? .allMachines {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "activity.scope") }
    }

    private(set) var deliveredScope: ActivityScope = .thisMachine

    private(set) var scopeNotice: String?
    private(set) var needsAccountSignIn = false

    var planLimits: [ProviderLimits] { PlanLimitsStore.shared.visible }
    var isLoadingLimits = false
    private var planUsageError: String?
    private var planLimitsError: String?
    var planErrorMessage: String? { planLimitsError ?? planUsageError }
    private(set) var hasLoadedPlanLimits = false
    private var limitsGeneration: UInt64 = 0
    private let layout = HomeLayout.shared

    var planBySource: [Bucket] = []

    var isLoading = false
    private(set) var isRefreshing = false
    var errorMessage: String?

    private(set) var isArchiveReady = false

    private(set) var hasConfirmedEmptyActivity = false

    private var hostRetryTask: Task<Void, Never>?
    private var hostRetryCount = 0
    private var calendarGeneration: UInt64 = 0
    private var lastLimitsLoadedAt: Date?
    private var lastLoadedAt: Date?
    private static let quietRefreshStale: TimeInterval = 45


    private(set) var hoveredDay: String?
    private(set) var hoveredDetail: DayDetail?
    private(set) var isLoadingDayDetail = false

    private(set) var selectedDay: HeatCell?
    private(set) var selectedDetail: DayDetail?
    private(set) var isLoadingSelectedDetail = false
    private(set) var selectedOverview: DayOverview?
    private(set) var isLoadingSelectedOverview = false

    private var dayDetailCache: [String: DayDetail] = [:]
    private var hoverDetailTask: Task<Void, Never>?
    private var selectedDetailTask: Task<Void, Never>?
    private var dayOverviewCache: [String: DayOverview] = [:]
    private var dayOverviewTask: Task<Void, Never>?

    var weekValue: Money {
        let micros = calendarDays.suffix(7).reduce(UInt64(0)) { $0.saturatingAdd($1.value) }
        return Money(micros: Int64(clamping: micros), estimated: false, complete: true)
    }

    var glance: ChatStartGlanceData? {
        guard calendar != nil else { return nil }
        let days = calendarDays.suffix(7).map(\.value)
        return ChatStartGlanceData(week: days)
    }

    var todayValue: Money {
        let micros = calendarDays.last { $0.date == calendar?.last }?.value ?? 0
        return Money(micros: Int64(clamping: micros), estimated: false, complete: true)
    }

    private var calendarDays: [HeatCell] {
        guard let calendar else { return [] }
        return calendar.rows.flatMap { $0.compactMap { $0 } }.sorted { $0.date < $1.date }
    }

    func load(quiet: Bool = false, refreshAccountGrid: Bool = false) async {
        let soft = quiet && calendar != nil
        if soft {
            guard !isRefreshing, !isLoading else { return }
            isRefreshing = true
        } else {
            isLoading = true
        }
        calendarGeneration &+= 1
        let generation = calendarGeneration
        let requestedScope = scope
        let ecosystemLease = EcosystemPublisher.lease
        defer {
            if generation == calendarGeneration {
                isLoading = false
                isRefreshing = false
            }
        }
        hasConfirmedEmptyActivity = false
        do {
            async let calendar = Bridge.activityCalendar(
                scope: scope.wire,
                force: refreshAccountGrid
            )
            let grid = try await calendar
            guard !Task.isCancelled, generation == calendarGeneration, scope == requestedScope else { return }
            self.calendar = grid
            EcosystemPublisher.publish(calendar: grid, lease: ecosystemLease)
            hasConfirmedEmptyActivity = grid == nil
            isArchiveReady = true
            let newScope: ActivityScope = grid?.scope == "account" ? .allMachines : .thisMachine
            let scopeChanged = newScope != deliveredScope
            if scopeChanged {
                invalidateArchiveCaches()
            }
            deliveredScope = newScope
            scopeNotice = grid?.notice
            needsAccountSignIn = grid?.noticeCode == "auth"

            if selectedDay == nil {
                pinToday()
            } else if scopeChanged {
                if let date = selectedDay?.date, let cell = cell(on: date) {
                    select(day: cell)
                } else {
                    selectedDay = nil
                    pinToday()
                }
            }

            errorMessage = nil
            lastLoadedAt = Date()
            hostRetryCount = 0
            hostRetryTask?.cancel()
        } catch {
            guard !Task.isCancelled, generation == calendarGeneration, scope == requestedScope else { return }
            hasConfirmedEmptyActivity = false
            if Bridge.isHostRecoveryError(error) {
                scheduleHostRetryIfNeeded(error)
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

    func refresh() async {
        let pinned = selectedDay?.date
        softInvalidateForRefresh()
        await load(quiet: true, refreshAccountGrid: true)
        if let pinned, let fresh = cell(on: pinned) { select(day: fresh) }
        await loadPlanLimits()
    }

    func refreshIfStale() async {
        if let last = lastLoadedAt,
           Date().timeIntervalSince(last) < Self.quietRefreshStale
        {
            return
        }
        let pinned = selectedDay?.date
        softInvalidateForRefresh()
        await load(quiet: true)
        if let pinned, let fresh = cell(on: pinned) { select(day: fresh) }
        await loadPlanLimits(force: false)
    }

    private func softInvalidateForRefresh() {
        dayDetailCache = [:]
        dayOverviewCache = [:]
        hoveredDay = nil
        hoveredDetail = nil
        isLoadingDayDetail = false
        hoverDetailTask?.cancel()
        selectedDetailTask?.cancel()
        dayOverviewTask?.cancel()
        if selectedDetail != nil { isLoadingSelectedDetail = true }
        if selectedOverview != nil { isLoadingSelectedOverview = true }
    }

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

    func hover(day: HeatCell?) {
        let date = day.flatMap { $0.value > 0 && !$0.isLocked ? $0.date : nil }
        guard date != hoveredDay else { return }
        hoverDetailTask?.cancel()
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
        hoverDetailTask = fetchDayDetail(day.date, settle: true)
    }

    private var todayCell: HeatCell? {
        guard let last = calendar?.last else { return nil }
        return cell(on: last)
    }

    private func cell(on date: String) -> HeatCell? {
        calendarDays.last { $0.date == date }
    }

    private func pinToday() {
        guard let today = todayCell else { return }
        select(day: today)
    }

    func select(day: HeatCell) {
        let isSameDay = selectedDay?.date == day.date
        selectedDay = day
        selectedDetailTask?.cancel()
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
            if !isSameDay { selectedDetail = nil }
            selectedDetailTask = fetchDayDetail(day.date, settle: false)
        }
        loadOverview(for: day.date, keepStale: isSameDay)
    }

    private func loadOverview(for date: String, keepStale: Bool = false) {
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
        if !keepStale { selectedOverview = nil }
        dayOverviewTask = Task { [weak self] in
            let query = Query(since: date, until: date)
            let sessionQuery = Query(since: date, until: date, limit: 80)
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

    private func fetchDayDetail(_ date: String, settle: Bool) -> Task<Void, Never> {
        let scope = deliveredScope.wire
        return Task { [weak self] in
            if settle {
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

    func setScope(_ new: ActivityScope) async {
        guard new != scope else { return }
        invalidateArchiveCaches()
        scope = new
        await load()
    }

    func invalidateArchiveCaches() {
        dayDetailCache = [:]
        dayOverviewCache = [:]
        hoveredDay = nil
        hoveredDetail = nil
        isLoadingDayDetail = false
        hoverDetailTask?.cancel()
        selectedDetailTask?.cancel()
        dayOverviewTask?.cancel()
        selectedDetail = nil
        selectedOverview = nil
        isLoadingSelectedDetail = false
        isLoadingSelectedOverview = false
    }

    func reloadAfterSync() async {
        let pinnedDate = selectedDay?.date
        invalidateArchiveCaches()
        await load(quiet: true, refreshAccountGrid: true)
        if let pinnedDate, let fresh = cell(on: pinnedDate) {
            select(day: fresh)
        }
        await loadPlanLimits()
    }

    func loadPlanLimits(force: Bool = true) async {
        let ecosystemLease = EcosystemPublisher.lease
        let owner = WorkSessionContext.shared.generation
        if !force, let last = lastLimitsLoadedAt, Date().timeIntervalSince(last) < 60 { return }
        guard !layout.hidden.contains(.limits), !Task.isCancelled, !isLoadingLimits else { return }
        limitsGeneration &+= 1
        let generation = limitsGeneration
        func current() -> Bool {
            generation == limitsGeneration && owner == WorkSessionContext.shared.generation
                && !layout.hidden.contains(.limits) && !Task.isCancelled
        }
        isLoadingLimits = true
        defer { if generation == limitsGeneration { isLoadingLimits = false } }
        async let usage: Void = loadPlanUsage(generation: generation)
        do {
            try await PlanLimitsStore.shared.refresh(force: force)
            guard current() else { return }
            EcosystemPublisher.publish(limits: planLimits, lease: ecosystemLease)
            hasLoadedPlanLimits = true
            lastLimitsLoadedAt = Date()
            planLimitsError = nil
        } catch is CancellationError {
        } catch {
            guard current() else { return }
            planLimitsError = error.localizedDescription
        }
        await usage
    }

    func hidePlanLimits() {
        limitsGeneration &+= 1
        isLoadingLimits = false
        planUsageError = nil
        planLimitsError = nil
    }

    private func loadPlanUsage(generation: UInt64) async {
        #if os(macOS)
        guard generation == limitsGeneration, !layout.hidden.contains(.limits), !Task.isCancelled else { return }
        do {
            let rows = try await Self.archiveOnly {
                try await Bridge.report(group: .source, query: Query(billing: "plan"))
            }
            guard generation == limitsGeneration, !layout.hidden.contains(.limits), !Task.isCancelled else { return }
            planBySource = rows
            planUsageError = nil
        } catch {
            guard generation == limitsGeneration, !layout.hidden.contains(.limits), !Task.isCancelled else { return }
            planUsageError = error.localizedDescription
        }
        #endif
    }

}

struct DayOverview: Sendable {
    var totals: Totals?
    var byModel: [Bucket]
    var bySource: [Bucket]
    var byProject: [Bucket]
    var bySession: [Bucket]
}
