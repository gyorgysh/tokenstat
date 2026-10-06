// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
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
}

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
}
#if os(iOS)
extension LiveWorkAttributes: ActivityAttributes {}
#endif
