// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with EcosystemSnapshot.swift.
import Foundation

@main struct EcosystemSnapshotTests {
    static func main() throws {
        let owner = "account:alice/example.com"
        let route = EcosystemRoute(screen: .workspaces, projectID: "remote:host:project / ?#&🧪", owner: owner)
        assert(EcosystemRoute(url: route.url) == route)
        for screen in EcosystemScreen.allCases {
            assert(EcosystemRoute(url: EcosystemRoute(screen: screen).url)?.screen == screen)
        }
        for section in EcosystemProjectSection.allCases {
            var sectionRoute = route
            sectionRoute.section = section
            assert(EcosystemRoute(url: sectionRoute.url) == sectionRoute)
        }
        let liveRoute = EcosystemRoute(screen: .workspaces, projectID: "remote:host:p", owner: owner, section: .chat, chatID: "chat /?#🧪")
        assert(EcosystemRoute(url: liveRoute.url) == liveRoute)
        for invalid in ["tokenstat://open/workspaces?project=p&owner=o&chat=x", "tokenstat://open/workspaces?project=p&owner=o&section=notes&chat=x", "tokenstat://open/workspaces?project=p&owner=o&section=chat&chat="] {
            assert(EcosystemRoute(url: URL(string: invalid)!) == nil)
        }
        var indexedURL = URLComponents(string: "tokenstat://open/workspaces")!
        indexedURL.queryItems = [.init(name: "entity", value: Data("\(owner)\n\(route.projectID!)".utf8).base64EncodedString())]
        assert(EcosystemRoute(url: indexedURL.url!) == route)
        for invalid in ["https://open/home", "tokenstat://open/unknown", "tokenstat://open/home?command=rm",
                        "tokenstat://open/workspaces?project=p", "tokenstat://open/home?project=p&owner=o",
                        "tokenstat://open/workspaces?project=p&project=q&owner=o", "tokenstat://open/home#work",
                        "tokenstat://user@open/home", "tokenstat://open/workspaces?project=&owner=o",
                        "tokenstat://open/workspaces?project=p&owner=o&entity",
                        "tokenstat://open/search?query=q&section", "tokenstat://open/workspaces?entity=garbage",
                        "tokenstat://open/workspaces?project=p&owner=o&section=execute"] {
            assert(EcosystemRoute(url: URL(string: invalid)!) == nil, invalid)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-10-06T23:59:00Z")!
        let usage = EcosystemUsage(updatedAt: now, scope: "All devices", days: [
            .init(day: "2026-09-29", value: 90_000_000, level: 4),
            .init(day: "2026-09-30", value: 50_000_000, level: 4, locked: true),
            .init(day: "2026-10-05", value: 1_500_000, level: 2),
            .init(day: "2026-10-06", value: 0, level: 0)
        ], streak: 1)
        assert(usage.today(at: now, calendar: calendar)?.value == 0) // Quiet is known zero.
        assert(usage.today(at: now.addingTimeInterval(120), calendar: calendar) == nil) // Midnight is unknown.
        assert(usage.week(at: now, calendar: calendar).map(\.day) == ["2026-09-30", "2026-10-05", "2026-10-06"])
        assert(EcosystemUsage.sum(usage.week(at: now, calendar: calendar)) == 1_500_000) // Locked values excluded.
        assert(usage.weekTotal(at: now, calendar: calendar) == nil) // Partial data is not a complete weekly total.
        assert(usage.weekWindow(at: now, calendar: calendar).count == 7)
        assert(usage.weekWindow(at: now, calendar: calendar).filter(\.locked).count == 5)
        assert(usage.weekWindow(at: now, calendar: calendar).last?.value == 0)
        let complete = EcosystemUsage(updatedAt: now, scope: "This device", days: (0..<7).map { offset in
            .init(day: EcosystemUsage.dayKey(calendar.date(byAdding: .day, value: -offset, to: now)!, calendar: calendar), value: 1_000_000, level: 1)
        }, streak: 7)
        assert(complete.weekTotal(at: now, calendar: calendar) == 7_000_000)
        assert(complete.weekTotal(at: now.addingTimeInterval(120), calendar: calendar) == nil)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        assert(usage.today(at: now, calendar: calendar) == nil) // Device timezone rollover.
        assert(EcosystemUsage.sum([.init(day: "a", value: .max, level: 4), .init(day: "b", value: 1, level: 1)]) == .max)
        assert(EcosystemUsage.displayMoney(18_420_000) == EcosystemUsage.money(18_420_000))
        assert(EcosystemUsage.displayMoney(1_234_567_890_000).hasSuffix(" USD"))
        assert(EcosystemUsage.displayMoney(UInt64.max).hasSuffix(" USD"))

        let search = EcosystemRoute(screen: .search, searchTerm: "project & docs 🧪")
        assert(EcosystemRoute(url: search.url) == search)
        assert(EcosystemRoute(url: URL(string: "tokenstat://open/home?query=test")!) == nil)
        assert(!EcosystemDay.validDate("2026-02-30"))
        assert(EcosystemDay.validDate("2024-02-29"))
        var merged = EcosystemSnapshot(owner: owner, projects: [
            .init(id: "local", name: "Local", host: "Mac"),
            .init(id: "remote:one:p", name: "One", host: "One"),
            .init(id: "remote:two:p", name: "Two", host: "Two")])
        merged.replaceProjects([], from: .peer("one"))
        assert(merged.projects.map(\.id) == ["local", "remote:two:p"])
        merged.replaceProjects([], from: .local)
        assert(merged.projects.map(\.id) == ["remote:two:p"])
        var invalid = EcosystemSnapshot.preview
        let duplicate = invalid.usage!.days[0]
        invalid.usage?.days.append(duplicate)
        assert(!invalid.isValid)
        invalid = .preview; invalid.usage?.days[0].level = -1
        assert(!invalid.isValid)
        invalid = .preview; invalid.owner = nil
        assert(!invalid.isValid)

        let quota = EcosystemLimitProvider(source: "future_vendor", observedAt: now, stale: false, windows: [
            .init(label: "weekly", percent: 104, resetsAt: now.addingTimeInterval(60)),
            .init(label: "monthly", percent: 20)])
        assert(quota.isValid && quota.windows[0].fraction == 1)
        assert(quota.peak(at: now)?.percent == 104)
        assert(quota.peak(at: now.addingTimeInterval(60))?.percent == 20) // Reset is unknown, never zero.
        assert(quota.isStale(at: now.addingTimeInterval(901)))
        assert(!EcosystemLimitWindow(label: "weekly", percent: .nan).isValid)
        assert(!EcosystemLimitWindow(label: "weekly", percent: -.infinity).isValid)
        var quotaSnapshot = EcosystemSnapshot(owner: owner, limits: [quota])
        assert(quotaSnapshot.isValid)
        quotaSnapshot.limits?.append(quota)
        assert(!quotaSnapshot.isValid)
        quotaSnapshot = .init(owner: nil, limits: [quota])
        assert(!quotaSnapshot.isValid)
        let oldSnapshot = try JSONDecoder().decode(EcosystemSnapshot.self, from: Data("{\"version\":1,\"owner\":\"preview\",\"projects\":[]}".utf8))
        assert(oldSnapshot.isValid && oldSnapshot.limits == nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EcosystemSnapshotStore(directory: directory)
        assert(store.read() == .empty)
        let snapshot = EcosystemSnapshot(owner: owner, usage: usage, projects: [.init(id: "p", name: "Project", host: "Mac")])
        assert(store.write(snapshot))
        assert(EcosystemSnapshotStore(directory: directory).read() == snapshot)
        assert(store.write(.empty) && store.read() == .empty) // Sign-out removes aggregate and projects.
        let file = directory.appendingPathComponent("ecosystem-v1.json")
        try Data("broken".utf8).write(to: file)
        assert(store.read() == .empty)
        var future = snapshot
        future.version = 2
        try JSONEncoder().encode(future).write(to: file)
        assert(store.read() == .empty)
        try Data(repeating: 0, count: 257 * 1024).write(to: file)
        assert(store.read() == .empty)
        assert(!EcosystemSnapshotStore(directory: nil).write(snapshot))
        print("Ecosystem: URL validation, midnight/timezone rollover, locked usage, saturation and snapshot persistence passed")
    }
}
