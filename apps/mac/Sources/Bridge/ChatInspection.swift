// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatInspection: Decodable, Sendable {
    struct Server: Decodable, Sendable, Identifiable {
        var name: String
        var status: String
        var source: String
        var tools: [String]?
        var id: String { name }
    }
    var backend: String
    var model: String?
    var contextUsed: UInt64?
    var contextWindow: UInt64?
    struct ContextPoint: Decodable, Sendable { var tokens: UInt64; var atMs: Int64 }
    struct PromptBreakdown: Decodable, Sendable { var input: UInt64; var cacheRead: UInt64; var cacheWrite: UInt64 }
    var contextBreakdown: PromptBreakdown?
    var contextHistory: [ContextPoint]?
    var contextSource: String?
    var windowSource: String?
    var tools: [String]?
    var usedTools: [String]
    var mcpServers: [Server]
    var mcpReported: Bool
    var observedAtMs: Int64?
    var currentRun: Bool
    var inventoryPartial: Bool?

    func hasLiveConnection(_ server: Server, running: Bool) -> Bool {
        running && currentRun && server.source == "agent" && server.status == "connected"
    }

    var fraction: Double? {
        guard let contextUsed, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextUsed) / Double(contextWindow))
    }
}
