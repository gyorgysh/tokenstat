// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// Everything the Insights screen shows, and the one place that talks to the
/// bridge.
///
/// Views stay declarative and never call `Bridge` directly, so when the host
/// daemon replaces the in-process bridge there is exactly one file to change.
@Observable
@MainActor
final class InsightsModel {
    enum Period: String, CaseIterable, Identifiable {
        case week = "7d"
        case month = "30d"
        case quarter = "90d"
        case all = "All"

        var id: String { rawValue }

        /// Days back from today, or nil for the whole archive.
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .all: return nil
            }
        }
    }

    /// Which breakdown the content pane is showing.
    enum Tab: String, CaseIterable, Hashable {
        case overview, models, projects, harnesses, sessions

        var label: String {
            switch self {
            case .overview: return "Overview"
            case .models: return "Models"
            case .projects: return "Projects"
            case .harnesses: return "Harnesses"
            case .sessions: return "Sessions"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .models: return "cpu"
            case .projects: return "folder"
            case .harnesses: return "terminal"
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
    var activeBlock: Block?

    /// Which harnesses ran in each archive project.
    ///
    /// Feeds the inspector when a project row is selected. Built from one
    /// two-level query rather than a query per project.
    var projectHarnesses: [ProjectHarnesses] = []

    var tab: Tab = .overview {
        didSet { if tab != oldValue { selected = nil } }
    }

    /// Row the inspector is describing. Cleared when the tab changes, because
    /// a row from another breakdown would be describing something else.
    var selected: Bucket?

    /// Rows for the current tab. Overview has no single list of its own.
    var rows: [Bucket] {
        switch tab {
        case .overview: return byModel
        case .models: return byModel
        case .projects: return byProject
        case .harnesses: return bySource
        case .sessions: return bySession
        }
    }

    /// Defaults to the whole archive. tokenstat exists because agents delete
    /// their own transcripts, so the first thing to show is everything that
    /// survived, not the last month of it.
    var period: Period = .all {
        didSet { if period != oldValue { reload() } }
    }

    var isLoading = false
    var isScanning = false
    /// Set when a load fails. The message comes from the core, which names the
    /// actual file or setting at fault, so it is shown rather than replaced.
    var errorMessage: String?

    private var loadTask: Task<Void, Never>?

    var query: Query {
        guard let days = period.days else { return Query() }
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        return Query(since: Self.dateFormatter.string(from: start))
    }

    /// The archive stores local dates as plain `YYYY-MM-DD` text, so the filter
    /// has to be built the same way rather than as an instant.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func load() async {
        if info == nil {
            do {
                info = try await Bridge.info()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        await refresh()
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let q = query
        do {
            // Independent queries, so let them overlap rather than serialize.
            async let totals = Bridge.totals(q)
            async let daily = Bridge.report(group: .day, query: q)
            async let byModel = Bridge.report(group: .model, query: q)
            async let byProject = Bridge.report(group: .project, query: q)
            async let bySource = Bridge.report(group: .source, query: q)
            async let bySession = Bridge.report(group: .session, query: q)
            async let blocks = Bridge.blocks(q)
            async let split = Bridge.reportSplit(group: .project, splitBy: .source, query: q)

            self.totals = try await totals
            self.daily = try await daily
            self.byModel = try await byModel
            self.byProject = try await byProject
            self.bySource = try await bySource
            self.bySession = try await bySession
            self.activeBlock = try await blocks.first(where: \.active)
            self.projectHarnesses = Self.buildProjectHarnesses(
                projects: self.byProject,
                split: try await split
            )
            // A selection from before the reload may no longer exist, and a
            // stale row would sit in the inspector describing nothing.
            if let key = selected?.key {
                selected = rows.first { $0.key == key }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Read every discoverable log source into the archive, then redraw.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            _ = try await Bridge.scan()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Harnesses that ran in the given project, largest first.
    func harnesses(inProject key: String) -> [SplitBucket] {
        projectHarnesses.first { $0.path == key }?.harnesses ?? []
    }

    /// Attach each project's harnesses to it.
    ///
    /// Order comes from `projects`, which the archive already returns busiest
    /// first, rather than from re-sorting the split. A project with no split
    /// rows still appears: it has usage, so hiding it would be a lie about the
    /// archive, even if the harness attribution is missing.
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

    /// Total value for the period, carrying the estimate and completeness
    /// qualifiers up from the rows it was built from.
    ///
    /// Taken from the model breakdown rather than the daily one because both
    /// cover the same events, and the model split is the one whose rows can
    /// each be priced directly.
    var periodValue: Money { byModel.totalValue }
}
