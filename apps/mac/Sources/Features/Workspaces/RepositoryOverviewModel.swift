// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class RepositoryOverviewModel {
    struct Usage: Equatable {
        var days: [UInt64]
        var agents: [Agent]
        var weekValue: Int64?

        var total: UInt64 { days.reduce(0) { $0.saturatingAdd($1) } }
        var week: UInt64 { days.suffix(7).reduce(0) { $0.saturatingAdd($1) } }
        var today: UInt64 { days.last ?? 0 }
    }

    struct Agent: Equatable, Identifiable {
        var id: String
        var tokens: UInt64
    }

    struct Pulls: Equatable {
        var open: [PullSummary]
        var marks: [String: [PullSummary]]
        var requested: Set<UInt32>
        var login: String?
        var webBase: String?

        func isMine(_ pull: PullSummary) -> Bool {
            guard let login, !login.isEmpty else { return false }
            return pull.author.caseInsensitiveCompare(login) == .orderedSame
        }
    }

    private(set) var days: [String] = RepositoryDays.keys()
    private(set) var usage: [String: Usage] = [:]
    private(set) var usageLoaded = false
    private(set) var pulls: [String: Pulls] = [:]
    var peekID: String?

    @ObservationIgnored private var usageAt: Date?
    @ObservationIgnored private var pullsAt: [String: Date] = [:]
    @ObservationIgnored private var generation: UInt64?
    private static let stale: TimeInterval = 120

    private func adoptSession() {
        let current = WorkSessionContext.shared.generation
        guard generation != current else { return }
        generation = current
        pulls = [:]
        pullsAt = [:]
    }

    static func usageNames(_ folders: [WorkspaceFolder]) -> [String: String] {
        let local = folders.filter { !$0.isRemote && !$0.isGeneral }
        let byName = Dictionary(grouping: local, by: \.name)
        return byName.compactMapValues { $0.count == 1 ? $0[0].id : nil }
    }

    func loadUsage(_ folders: [WorkspaceFolder], force: Bool = false) async {
        let names = Self.usageNames(folders)
        let keys = RepositoryDays.keys()
        let covered = Set(names.values).isSubset(of: usageAsked) && keys == days
        if !force, covered, let usageAt, Date().timeIntervalSince(usageAt) < Self.stale { return }
        usageAt = Date()
        usageAsked = Set(names.values)
        let since = keys.first
        let weekStart = keys.suffix(7).first
        do {
            async let byDay = Bridge.reportSplit(group: .project, splitBy: .day, query: Query(since: since))
            async let bySource = Bridge.reportSplit(group: .project, splitBy: .source, query: Query(since: since))
            async let week = Bridge.report(group: .project, query: Query(since: weekStart))
            let (dayRows, sourceRows, weekRows) = try await (byDay, bySource, week)
            guard !Task.isCancelled else { return }
            let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
            var next: [String: Usage] = [:]
            for (name, id) in names {
                var tokens = [UInt64](repeating: 0, count: keys.count)
                for row in dayRows where row.key == name {
                    guard let at = index[row.split] else { continue }
                    tokens[at] = tokens[at].saturatingAdd(row.counters.total)
                }
                guard tokens.contains(where: { $0 > 0 }) else { continue }
                var agents: [String: UInt64] = [:]
                for row in sourceRows where row.key == name {
                    agents[harnessCanonicalID(row.split), default: 0] += row.counters.total
                }
                let bucket = weekRows.first { $0.key == name }
                next[id] = Usage(
                    days: tokens,
                    agents: agents.map { Agent(id: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens },
                    weekValue: bucket.flatMap { $0.valueMicros > 0 ? $0.valueMicros : nil })
            }
            if days != keys { days = keys }
            if usage != next { usage = next }
            usageLoaded = true
        } catch {
            usageAt = nil
        }
    }
    @ObservationIgnored private var usageAsked: Set<String> = []

    func loadPulls(_ folders: [WorkspaceFolder]) async {
        adoptSession()
        let owner = generation
        let due = folders.filter { folder in
            guard !folder.isRemote, folder.exists, folder.git?.isRepo == true else { return false }
            return pullsAt[folder.id].map { Date().timeIntervalSince($0) >= Self.stale } ?? true
        }
        for start in stride(from: 0, to: due.count, by: 3) {
            guard !Task.isCancelled, owner == WorkSessionContext.shared.generation else { return }
            let batch = due[start..<min(start + 3, due.count)]
            for folder in batch { pullsAt[folder.id] = Date() }
            await withTaskGroup(of: Void.self) { group in
                for folder in batch {
                    let id = folder.id
                    group.addTask { await self.loadPulls(id, owner: owner) }
                }
            }
            if Task.isCancelled { for folder in batch { pullsAt[folder.id] = nil } }
        }
    }

    private func loadPulls(_ id: String, owner: UInt64?) async {
        guard let availability = try? await Bridge.pullAvailability(workspaceID: id), availability.state == "ready" else {
            if !Task.isCancelled, pulls[id] != nil { pulls[id] = nil }
            return
        }
        async let open = Bridge.pullList(workspaceID: id, scope: .all, state: .open)
        async let recent = Bridge.pullList(workspaceID: id, scope: .all, state: .all)
        async let requested = Bridge.pullList(workspaceID: id, scope: .reviewRequested, state: .open)
        guard let openRows = try? await open else { return }
        let recentRows = (try? await recent) ?? []
        let requestedRows = (try? await requested) ?? []
        guard !Task.isCancelled, owner == WorkSessionContext.shared.generation else { return }
        var base: String?
        if let host = availability.host, let name = availability.repositoryName { base = "https://\(host)/\(name)" }
        let next = Pulls(open: openRows, marks: Self.marks(openRows + recentRows),
                         requested: Set(requestedRows.map(\.number)), login: availability.login, webBase: base)
        if pulls[id] != next { pulls[id] = next }
    }

    private static func marks(_ pulls: [PullSummary]) -> [String: [PullSummary]] {
        var seen = Set<UInt32>()
        var out: [String: [PullSummary]] = [:]
        for pull in pulls where seen.insert(pull.number).inserted {
            guard let date = parseServerDate(pull.createdAt) else { continue }
            out[RepositoryDays.key(date), default: []].append(pull)
        }
        return out
    }
}
#endif
