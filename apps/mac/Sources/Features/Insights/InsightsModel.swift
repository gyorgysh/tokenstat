// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

@Observable
@MainActor
final class InsightsModel {
    enum Period: String, CaseIterable, Identifiable {
        case week = "7d"
        case month = "30d"
        case quarter = "90d"
        case all = "All"

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .all: return nil
            }
        }
    }

    enum Tab: String, CaseIterable, Hashable {
        case overview, models, projects, harnesses, profiles, sessions

        var label: String {
            switch self {
            case .overview: return L10n.text("apple.insightsmodel.overview.d4b1ea57")
            case .models: return L10n.text("apple.insightsmodel.models.d17d2d78")
            case .projects: return L10n.text("common.projects")
            case .harnesses: return L10n.text("apple.insightsmodel.coding_tools.6032f740")
            case .profiles: return L10n.text("apple.profiles.title")
            case .sessions: return L10n.text("apple.insightsmodel.sessions.6fa3cbf4")
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .models: return "cpu"
            case .projects: return "folder"
            case .harnesses: return "terminal"
            case .profiles: return "person.2"
            case .sessions: return "bubble.left.and.bubble.right"
            }
        }
    }

    var info: Info?
    var totals: Totals?
    var daily: [Bucket] = []
    var byModel: [Bucket] = []
    var byProject: [Bucket] = []
    var bySource: [Bucket] = []
    var bySession: [Bucket] = []
    var byProfile: [Bucket] = []
    var activeBlock: Block?

    var projectHarnesses: [ProjectHarnesses] = []

    var tab: Tab = .overview {
        didSet { if tab != oldValue { selected = nil } }
    }

    var selected: Bucket?

    var rows: [Bucket] {
        switch tab {
        case .overview: return byModel
        case .models: return byModel
        case .projects: return byProject
        case .harnesses: return bySource
        case .profiles: return byProfile
        case .sessions: return bySession
        }
    }

    var period: Period = .all {
        didSet {
            guard period != oldValue else { return }
            focusedDay = nil
            reload()
        }
    }

    var isLoading = false
    var isScanning = false
    var isFetching = false
    var scanCooldownUntil: Date?
    var fetchCooldownUntil: Date?
    var actionMessage: String?
    private var actionGeneration = 0
    var errorMessage: String?

    private var loadTask: Task<Void, Never>?

    private(set) var focusedDay: String?

    func focusOn(day: String) {
        guard focusedDay != day else { return }
        focusedDay = day
        selected = nil
        reload()
    }

    func clearFocusedDay() {
        guard focusedDay != nil else { return }
        focusedDay = nil
        reload()
    }

    var query: Query {
        if let focusedDay {
            return Query(since: focusedDay, until: focusedDay)
        }
        guard let days = period.days else { return Query() }
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        return Query(since: Self.dateFormatter.string(from: start), billing: nil)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func load() async {
        await refresh()
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { await refresh() }
    }

    private var refreshGeneration: UInt64 = 0

    private func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == refreshGeneration { isLoading = false } }

        let q = query
        do {
            let snapshot = try await Bridge.insightsSnapshot(q)
            guard !Task.isCancelled, generation == refreshGeneration, query == q else { return }
            self.info = snapshot.info
            self.totals = snapshot.totals
            self.daily = snapshot.daily
            self.byModel = snapshot.byModel
            self.byProject = snapshot.byProject
            self.bySource = snapshot.bySource
            self.bySession = snapshot.bySession
            self.byProfile = snapshot.byProfile ?? []
            if tab == .profiles && !byProfile.contains(where: { $0.key != AgentProfiles.system }) { tab = .overview }
            if byProfile.contains(where: { $0.key != AgentProfiles.system }) {
                try? await AgentProfileCatalog.shared.refresh()
            }
            self.activeBlock = snapshot.activeBlock
            self.projectHarnesses = Self.buildProjectHarnesses(
                projects: self.byProject,
                split: snapshot.projectHarnesses
            )
            if let key = selected?.key {
                selected = rows.first { $0.key == key }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration, query == q else { return }
            errorMessage = error.localizedDescription
        }
    }

    func scan() async {
        guard !isScanning, scanCooldownUntil == nil else { return }
        isScanning = true
        actionMessage = nil
        defer { isScanning = false }
        do {
            let report = try await Bridge.scan()
            showAction(L10n.text("apple.insightsmodel.scan_complete_added_0_new_events_from_1_fi.0eff738d", "\(report.eventsNew)", "\(report.filesRead)"))
            startCooldown(seconds: 10, clearing: \.scanCooldownUntil)
            await refresh()
            NotificationCenter.default.post(name: .archiveDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchRemotes() async {
        guard !isFetching, fetchCooldownUntil == nil else { return }
        isFetching = true
        actionMessage = nil
        defer { isFetching = false }
        do {
            let reports = try await Bridge.fetchRemotes()
            let details = reports.compactMap(\.message).joined(separator: " · ")
            if reports.contains(where: { $0.failed == true || ($0.vendor == "cursor" && $0.skippedNoToken) }) {
                errorMessage = details
            } else {
                showAction(details.isEmpty ? L10n.text("apple.insightsmodel.remote_fetch_complete.2bfec637") : details)
                startCooldown(seconds: 30, clearing: \.fetchCooldownUntil)
            }
            await refresh()
            NotificationCenter.default.post(name: .archiveDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCooldown(seconds: TimeInterval, clearing: ReferenceWritableKeyPath<InsightsModel, Date?>) {
        let until = Date().addingTimeInterval(seconds)
        self[keyPath: clearing] = until
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self[keyPath: clearing] == until else { return }
            self[keyPath: clearing] = nil
        }
    }

    private func showAction(_ message: String) {
        actionGeneration += 1
        let generation = actionGeneration
        actionMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.actionGeneration == generation else { return }
            self.actionMessage = nil
        }
    }

    func harnesses(inProject key: String) -> [SplitBucket] {
        projectHarnesses.first { $0.path == key }?.harnesses ?? []
    }

    private static func buildProjectHarnesses(
        projects: [Bucket],
        split: [SplitBucket]
    ) -> [ProjectHarnesses] {
        let byPath = Dictionary(grouping: split, by: \.key)
        return projects.map { project in
            ProjectHarnesses(
                path: project.key,
                harnesses: byPath[project.key] ?? [],
                tokens: project.counters.total
            )
        }
    }

    var periodValue: Money { byModel.totalValue }
}
