// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit
#if os(iOS)
import ActivityKit
#endif

enum LiveWorkPhase: String, Codable, Hashable, Sendable {
    case working, waiting, idle, done, failed, stopped
    var finished: Bool { self == .done || self == .failed || self == .stopped }
    var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .idle: "Idle"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    static func terminal(alive: Bool, exitCode: Int?, activity: String?, attention: String?) -> Self {
        if !alive { return exitCode.map { $0 == 0 ? .done : .failed } ?? .stopped }
        if !(attention?.isEmpty ?? true) { return .waiting }
        return ["idle", "done", "error"].contains(activity ?? "") ? .idle : .working
    }
}

enum LiveWorkKind: String, Codable, Hashable, Sendable { case chat, terminal }

struct LiveWorkOverviewItem: Codable, Hashable, Sendable {
    var key: String
    var kind: LiveWorkKind
    var phase: LiveWorkPhase
}

struct LiveWorkOverview: Codable, Hashable, Sendable {
    var working = 0
    var waiting = 0
    var idle = 0
    var done = 0
    var failed = 0
    var total = 0
    var computers = 1
    var offline = 0
    var items: [LiveWorkOverviewItem] = []
    var phase: LiveWorkPhase { waiting > 0 ? .waiting : working > 0 ? .working : .idle }
    var remaining: Int { max(0, total - items.count) }

    enum CodingKeys: String, CodingKey { case working, waiting, idle, done, failed, total, computers, offline, items }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        working = try c.decode(Int.self, forKey: .working)
        waiting = try c.decode(Int.self, forKey: .waiting)
        idle = try c.decode(Int.self, forKey: .idle)
        done = try c.decode(Int.self, forKey: .done)
        failed = try c.decode(Int.self, forKey: .failed)
        total = try c.decode(Int.self, forKey: .total)
        computers = try c.decodeIfPresent(Int.self, forKey: .computers) ?? 1
        offline = try c.decodeIfPresent(Int.self, forKey: .offline) ?? 0
        items = try c.decode([LiveWorkOverviewItem].self, forKey: .items)
    }

    static func merged(_ summaries: [Self], offline: Int = 0) -> Self {
        var result = Self()
        result.computers = summaries.count + offline
        result.offline = offline
        for summary in summaries {
            result.working += summary.working; result.waiting += summary.waiting
            result.idle += summary.idle; result.done += summary.done; result.failed += summary.failed
            result.total += summary.total
            result.items += summary.items
        }
        let priority: [LiveWorkPhase: Int] = [.waiting: 0, .working: 1, .failed: 2, .done: 3, .idle: 4]
        result.items.sort {
            let a = priority[$0.phase] ?? 5, b = priority[$1.phase] ?? 5
            return a == b ? $0.key < $1.key : a < b
        }
        result.items = Array(result.items.prefix(3))
        return result
    }
}

struct LiveWorkHostOverview: Codable, Sendable {
    struct Hint: Codable, Sendable {
        var key: String
        var kind: LiveWorkKind
        var id: String
        var workspaceID: String
        var name: String
        enum CodingKeys: String, CodingKey {
            case key, kind, id, name
            case workspaceID = "workspaceId"
        }
    }
    var summary: LiveWorkOverview
    var hints: [Hint]
}

struct LiveWorkAttributes: Codable, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: LiveWorkPhase
        // Explicit Unix seconds keep the APNs schema independent of Date encoders.
        var updatedAt: Double
        var overview: LiveWorkOverview? = nil
        var computersOffline: Bool {
            guard let overview else { return false }
            return overview.computers > 0 && overview.offline == overview.computers
        }
    }
    var startedAt: Double
    var owner: String
    var peer: String
    var key: String
    var revision: String
    var projectName: String
    var route: String
    // Local labels/routes never pass through the push service.
    struct Hint: Codable, Hashable, Sendable { var name: String; var route: String }
    var overviewPeers: [String]? = nil
    var overviewHints: [String: Hint]? = nil

    static var overviewKey: String {
        SHA256.hash(data: Data("overview:v1".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func preferredRoute(for state: ContentState) -> String {
        if let waiting = state.overview?.items.first(where: { $0.phase == .waiting }),
           let hint = overviewHints?[waiting.key] { return hint.route }
        return route
    }

    static func key(kind: LiveWorkKind, id: String) -> String {
        SHA256.hash(data: Data("\(kind.rawValue):\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func destination(kind: LiveWorkKind, id: String, peer: String, workspaceID: String, owner: String) -> EcosystemRoute {
        // Mobile models can carry a raw host workspace ID or the app's qualified ID.
        let prefix = "remote:\(peer):"
        let projectID = workspaceID.hasPrefix(prefix) ? workspaceID : prefix + workspaceID
        return EcosystemRoute(screen: .workspaces, projectID: projectID, owner: owner,
                              section: kind == .chat ? .chat : .sessions,
                              chatID: kind == .chat ? id : nil, terminalID: kind == .terminal ? id : nil)
    }
}
#if os(iOS)
extension LiveWorkAttributes: ActivityAttributes {}
#endif
