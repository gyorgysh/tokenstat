// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatInspection: Decodable, Sendable {
    struct Activity: Decodable, Sendable {
        struct Goal: Decodable, Sendable {
            var objective: String
            var status: String
            var tokenBudget: UInt64?
            var tokensUsed: UInt64?
            var timeBudgetSeconds: UInt64?
            var timeUsedSeconds: UInt64?
            var source: String
        }
        struct Step: Decodable, Sendable {
            var text: String
            var status: String
        }
        struct Agent: Decodable, Sendable, Identifiable {
            var id: String
            var name: String?
            var task: String?
            var status: String
            var model: String?
            var source: String
        }
        var goal: Goal?
        var plan: [Step]
        var planSource: String?
        var agents: [Agent]
        var goalReported: Bool
        var planReported: Bool
        var agentsReported: Bool
        var partial: Bool
        var live: Bool

        var hasContent: Bool { goal != nil || !plan.isEmpty || !agents.isEmpty }
        var completedSteps: Int { plan.filter { $0.status == "completed" }.count }
        var runningAgents: Int? {
            guard live, agentsReported,
                  agents.allSatisfy({ ["pending", "running", "waiting", "completed", "failed", "stopped"].contains($0.status) }) else { return nil }
            return agents.filter { $0.status == "running" }.count
        }
        func agentStatus(_ agent: Agent, live: Bool? = nil) -> String {
            !(live ?? self.live) && ["running", "pending", "waiting"].contains(agent.status) ? "unknown" : agent.status
        }
    }
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
    var activity: Activity?

    func hasLiveConnection(_ server: Server, running: Bool) -> Bool {
        running && currentRun && server.source == "agent" && server.status == "connected"
    }

    var fraction: Double? {
        guard let contextUsed, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextUsed) / Double(contextWindow))
    }

    /// Fractions of capacity, with a single used segment when categories
    /// are absent or inconsistent. Never let malformed telemetry overfill.
    var contextSegments: [Double] {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return [] }
        let denominator = Double(max(used, window))
        if let split = contextBreakdown {
            let (cached, firstOverflow) = split.cacheRead.addingReportingOverflow(split.cacheWrite)
            let (total, secondOverflow) = cached.addingReportingOverflow(split.input)
            if !firstOverflow, !secondOverflow, total == used {
                return [split.input, split.cacheRead, split.cacheWrite].map { Double($0) / denominator }
            }
        }
        return [Double(used) / denominator]
    }
}
