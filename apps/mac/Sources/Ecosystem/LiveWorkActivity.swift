// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit
#if os(iOS)
import ActivityKit
#endif

enum LiveWorkPhase: String, Codable, Hashable, Sendable {
    case working, waiting, done, failed, stopped
    var finished: Bool { self == .done || self == .failed || self == .stopped }
    var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .done: "Done"
        case .failed: "Needs attention"
        case .stopped: "Stopped"
        }
    }

    static func terminal(alive: Bool, exitCode: Int?, activity: String?, attention: String?) -> Self {
        if !alive { return exitCode.map { $0 == 0 ? .done : .failed } ?? .stopped }
        return attention != nil || activity == "idle" ? .waiting : .working
    }
}

enum LiveWorkKind: String, Sendable { case chat, terminal }

struct LiveWorkAttributes: Codable, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: LiveWorkPhase
        // Explicit Unix seconds keep the APNs schema independent of Date encoders.
        var updatedAt: Double
    }
    var startedAt: Double
    var owner: String
    var peer: String
    var key: String
    var revision: String
    var projectName: String
    var route: String

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
