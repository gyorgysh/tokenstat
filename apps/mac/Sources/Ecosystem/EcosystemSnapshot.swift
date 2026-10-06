// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum EcosystemScreen: String, Codable, CaseIterable, Sendable {
    case home, workspaces, insights, machines, ssh, account, search

    var title: String {
        switch self {
        case .home: "Home"
        case .workspaces: "Workspaces"
        case .insights: "Insights"
        case .machines: "Devices"
        case .ssh: "SSH"
        case .account: "Account"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.3x3.fill"
        case .workspaces: "folder.fill"
        case .insights: "chart.bar.xaxis"
        case .machines: "laptopcomputer"
        case .ssh: "terminal"
        case .account: "person.crop.circle"
        case .search: "magnifyingglass"
        }
    }
}

/// Only navigation identifiers enter URLs. Never accept a command or file path.
struct EcosystemRoute: Equatable, Sendable {
    var screen: EcosystemScreen
    var projectID: String?
    var owner: String?
    var searchTerm: String?
    var section: EcosystemProjectSection?
    var chatID: String?

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "tokenstat"
        parts.host = "open"
        parts.path = "/\(screen.rawValue)"
        if let projectID, let owner {
            parts.queryItems = [URLQueryItem(name: "project", value: projectID),
                                URLQueryItem(name: "owner", value: owner)]
            if let section { parts.queryItems?.append(URLQueryItem(name: "section", value: section.rawValue)) }
            if let chatID { parts.queryItems?.append(URLQueryItem(name: "chat", value: chatID)) }
        }
        if let searchTerm, screen == .search { parts.queryItems = [URLQueryItem(name: "query", value: searchTerm)] }
        return parts.url!
    }

    init(screen: EcosystemScreen, projectID: String? = nil, owner: String? = nil, searchTerm: String? = nil, section: EcosystemProjectSection? = nil, chatID: String? = nil) {
        self.screen = screen
        self.projectID = projectID
        self.owner = owner
        self.searchTerm = searchTerm
        self.section = section
        self.chatID = chatID
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "tokenstat", parts.host == "open",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil,
              let screen = EcosystemScreen(rawValue: String(parts.path.dropFirst())) else { return nil }
        let items = parts.queryItems ?? []
        guard items.allSatisfy({ ["project", "owner", "query", "section", "entity", "chat"].contains($0.name) }),
              items.allSatisfy({ $0.value != nil }),
              Set(items.map(\.name)).count == items.count else { return nil }
        if let entity = items.first(where: { $0.name == "entity" })?.value {
            guard items.count == 1, screen == .workspaces, entity.utf8.count <= 4096,
                  let data = Data(base64Encoded: entity), let value = String(data: data, encoding: .utf8),
                  let split = value.firstIndex(of: "\n") else { return nil }
            let owner = String(value[..<split])
            let project = String(value[value.index(after: split)...])
            guard !owner.isEmpty, !project.isEmpty, owner.utf8.count <= 2048, project.utf8.count <= 2048 else { return nil }
            self.init(screen: screen, projectID: project, owner: owner)
            return
        }
        let project = items.first { $0.name == "project" }?.value
        let owner = items.first { $0.name == "owner" }?.value
        let sectionValue = items.first { $0.name == "section" }?.value
        let section = sectionValue.flatMap(EcosystemProjectSection.init(rawValue:))
        guard sectionValue == nil || section != nil else { return nil }
        let chat = items.first { $0.name == "chat" }?.value
        guard chat == nil || (screen == .workspaces && section == .chat && project != nil && owner != nil) else { return nil }
        let query = items.first { $0.name == "query" }?.value
        guard items.isEmpty || (screen == .workspaces && project != nil && owner != nil && query == nil)
                || (screen == .search && query != nil && project == nil && owner == nil && section == nil),
              [project, owner, query, chat].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { return nil }
        self.init(screen: screen, projectID: project, owner: owner, searchTerm: query, section: section, chatID: chat)
    }
}

struct EcosystemDay: Codable, Hashable, Sendable, Identifiable {
    var id: String { day }
    var day: String
    var value: UInt64
    var level: Int
    var locked: Bool = false
}

struct EcosystemProject: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var host: String
}

struct EcosystemUsage: Codable, Equatable, Sendable {
    var updatedAt: Date
    var scope: String
    var days: [EcosystemDay]
    var streak: Int

    /// Calendar dates follow the host's timezone. A previous day's value must
    /// never silently become today's value after midnight or a timezone change.
    func today(at date: Date = Date(), calendar: Calendar = .current) -> EcosystemDay? {
        days.first { $0.day == Self.dayKey(date, calendar: calendar) && !$0.locked }
    }

    func week(at date: Date = Date(), calendar: Calendar = .current) -> [EcosystemDay] {
        (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            let key = Self.dayKey(day, calendar: calendar)
            return days.first { $0.day == key }
        }
    }

    func weekWindow(at date: Date = Date(), calendar: Calendar = .current) -> [EcosystemDay] {
        (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            let key = Self.dayKey(day, calendar: calendar)
            return days.first { $0.day == key } ?? EcosystemDay(day: key, value: 0, level: 0, locked: true)
        }
    }

    func weekTotal(at date: Date = Date(), calendar: Calendar = .current) -> UInt64? {
        let days = week(at: date, calendar: calendar)
        guard days.count == 7, days.allSatisfy({ !$0.locked }) else { return nil }
        return Self.sum(days)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func money(_ micros: UInt64) -> String {
        (Double(micros) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func displayMoney(_ micros: UInt64) -> String {
        guard micros >= 10_000_000_000 else { return money(micros) }
        return (Double(micros) / 1_000_000).formatted(.number.notation(.compactName).precision(.fractionLength(2))) + " USD"
    }

    static func sum(_ days: [EcosystemDay]) -> UInt64 {
        days.filter { !$0.locked }.reduce(0) { sum, day in
            let result = sum.addingReportingOverflow(day.value)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }
}

/// A small, versioned snapshot. No credentials, paths, messages or drafts.
struct EcosystemSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var owner: String?
    var usage: EcosystemUsage?
    var projects: [EcosystemProject] = []
    var refreshFailed: Bool?

    mutating func replaceProjects(_ newProjects: [EcosystemProject], from source: EcosystemProjectSource) {
        projects.removeAll { source.contains($0.id) }
        var seen = Set<String>()
        projects = Array((newProjects + projects).filter { seen.insert($0.id).inserted }.prefix(24))
    }

    var isValid: Bool {
        guard version == 1, projects.count <= 24,
              Set(projects.map(\.id)).count == projects.count else { return false }
        guard let owner else { return usage == nil && projects.isEmpty }
        guard !owner.isEmpty, owner.utf8.count <= 2048,
              projects.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.id.utf8.count <= 2048 && $0.name.utf8.count <= 512 && $0.host.utf8.count <= 512 }) else { return false }
        guard let usage else { return true }
        return usage.updatedAt.timeIntervalSince1970.isFinite && usage.streak >= 0 && usage.streak <= 36600
            && ["All devices", "This device"].contains(usage.scope) && usage.days.count <= 35
            && Set(usage.days.map(\.day)).count == usage.days.count
            && usage.days.allSatisfy { (0...4).contains($0.level) && EcosystemDay.validDate($0.day) }
    }

    static let empty = Self()

    static var preview: Self {
        let calendar = Calendar.current
        let values: [UInt64] = [8_400_000, 19_700_000, 5_300_000, 26_400_000, 14_600_000, 32_800_000, 18_420_000]
        let days = (0..<35).map { index in
            EcosystemDay(day: EcosystemUsage.dayKey(calendar.date(byAdding: .day, value: index - 34, to: Date())!),
                         value: values[index % 7], level: (index % 4) + 1)
        }
        return Self(owner: "preview", usage: EcosystemUsage(updatedAt: Date(), scope: "All devices", days: days, streak: 6),
                    projects: [EcosystemProject(id: "preview-1", name: "tokenstat", host: "MacBook Pro"),
                               EcosystemProject(id: "preview-2", name: "Studio", host: "Mac mini")])
    }
}

struct EcosystemSnapshotStore {
    static let appGroup = "group.ai.tokenstat.tokenstat"
    static let widgetKinds = ["ai.tokenstat.usage", "ai.tokenstat.launcher"]
    let directory: URL?

    static var defaultDirectory: URL? {
        #if ECOSYSTEM_QA && os(macOS)
        // Desktop fixture rendering must never overwrite the signed-in app's shared cache.
        return FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-widget-qa-\(ProcessInfo.processInfo.processIdentifier)")
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #endif
    }
    init(directory: URL? = Self.defaultDirectory) {
        self.directory = directory
    }

    func read() -> EcosystemSnapshot {
        #if os(watchOS)
        return EcosystemWatchPacketStore(directory: directory).read()?.snapshot ?? .empty
        #else
        guard let directory,
              let data = Self.readBoundedData(at: directory.appendingPathComponent("ecosystem-v1.json")),
              let snapshot = try? JSONDecoder().decode(EcosystemSnapshot.self, from: data),
              snapshot.isValid else { return .empty }
        return snapshot
        #endif
    }

    static func readBoundedData(at url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 256 * 1024 + 1), data.count <= 256 * 1024 else { return nil }
        return data
    }

    @discardableResult
    func write(_ snapshot: EcosystemSnapshot) -> Bool {
        guard let directory, snapshot.isValid,
              let data = try? JSONEncoder().encode(snapshot), data.count <= 256 * 1024 else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("ecosystem-v1.json")
            try data.write(to: file, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: file.path)
            #endif
            var excluded = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            return true
        } catch { return false }
    }
}

struct EcosystemPublicationLease: Equatable, Sendable {
    let owner: String
    let generation: UUID
}

enum EcosystemProjectSource: Equatable, Sendable {
    case local, peer(String)
    func contains(_ id: String) -> Bool {
        switch self {
        case .local: return !id.hasPrefix("remote:")
        case .peer(let key): return id.hasPrefix("remote:\(key):")
        }
    }
}

extension EcosystemDay {
    static func validDate(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              key.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        return EcosystemUsage.dayKey(date, calendar: calendar) == key
    }
}

enum EcosystemProjectSection: String, Codable, CaseIterable, Sendable {
    case sessions, chat, changes, history, pulls, todo, notes, workflows, automations, files, browser
}
