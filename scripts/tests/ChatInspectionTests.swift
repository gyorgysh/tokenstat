// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatInspection.swift. SessionIdentities.swift.
import Foundation

@main struct ChatInspectionTests {
    static func main() throws {
        let wire = Data(#"{"backend":"claude","model":"model","contextUsed":1234,"contextWindow":200000,"contextSource":"lastInput","windowSource":"agent","tools":["Read"],"usedTools":["Read"],"mcpServers":[{"name":"godot-mcp","status":"connected","source":"agent","tools":["scene"]},{"name":"tokenstat-mcp","status":"configured","source":"configuration","tools":null}],"mcpReported":true,"observedAtMs":1,"currentRun":true}"#.utf8)
        let value = try JSONDecoder().decode(ChatInspection.self, from: wire)
        precondition(value.contextUsed == 1234 && value.contextWindow == 200000)
        precondition(value.sessions == nil, "Inspection remains compatible with hosts predating session identity telemetry")
        var sessionWire = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        sessionWire["sessions"] = ["entries": [["backend": "claude", "id": "reported-native", "status": "current"]], "total": 1, "truncated": false]
        let withSessions = try JSONDecoder().decode(ChatInspection.self, from: JSONSerialization.data(withJSONObject: sessionWire))
        precondition(withSessions.sessions?.entries.first?.id == "reported-native" && withSessions.contextUsed == 1234)
        sessionWire["sessions"] = false
        let malformedSessions = try JSONDecoder().decode(ChatInspection.self, from: JSONSerialization.data(withJSONObject: sessionWire))
        precondition(malformedSessions.contextUsed == 1234 && malformedSessions.sessions?.entries.isEmpty == true,
                     "Malformed optional identity metadata must not cost a chat its context inspection")
        precondition(value.mcpServers[0].status == "connected" && value.mcpServers[1].status == "configured")
        precondition(value.mcpServers[1].tools == nil, "Unknown inventory must remain unknown")
        precondition(value.hasLiveConnection(value.mcpServers[0], running: true))
        precondition(!value.hasLiveConnection(value.mcpServers[0], running: false), "Idle agents only have historical reports")
        precondition(!value.hasLiveConnection(value.mcpServers[1], running: true), "Configured entries cannot claim a live connection")
        var laterTurn = value
        laterTurn.currentRun = false
        precondition(!laterTurn.hasLiveConnection(value.mcpServers[0], running: true), "A new turn cannot claim a predecessor's connection")
        let noTelemetry = Data(#"{"backend":"sh","contextUsed":null,"contextWindow":null,"tools":null,"usedTools":[],"mcpServers":[],"mcpReported":false,"currentRun":false}"#.utf8)
        let unknown = try JSONDecoder().decode(ChatInspection.self, from: noTelemetry)
        precondition(unknown.fraction == nil && unknown.contextUsed == nil && unknown.tools == nil)
        precondition(unknown.activity == nil, "Hosts predating activity remain readable without inventing zero subagents")
        let activityWire = Data(#"{"goal":{"objective":"Finish the migration","status":"active","tokenBudget":40000,"tokensUsed":12000,"timeUsedSeconds":45,"source":"agent"},"plan":[{"text":"Inspect","status":"completed"},{"text":"Implement","status":"inProgress"}],"planSource":"agent","agents":[{"id":"child","name":"Reviewer","task":"Check the migration","status":"running","model":"codex","source":"agent"}],"goalReported":true,"planReported":true,"agentsReported":true,"partial":false,"live":true}"#.utf8)
        var activity = try JSONDecoder().decode(ChatInspection.Activity.self, from: activityWire)
        precondition(activity.goal?.objective == "Finish the migration" && activity.goal?.tokensUsed == 12000)
        precondition(activity.completedSteps == 1 && activity.runningAgents == 1 && activity.hasContent)
        precondition(activity.agentStatus(activity.agents[0], live: false) == "unknown",
                     "A failed refresh cannot keep an agent looking live")
        activity.agents[0].status = "unknown"
        precondition(activity.runningAgents == nil, "Known child identities without lifecycle cannot claim zero running")
        activity.agents[0].status = "running"
        activity.live = false
        precondition(activity.runningAgents == nil && activity.agentStatus(activity.agents[0]) == "unknown",
                     "Previous-run subagents are historical reports")
        var bounded = value
        bounded.contextWindow = 0
        precondition(bounded.fraction == nil, "A bad host denominator must not produce NaN or infinity")
        bounded.contextWindow = 1
        bounded.contextUsed = .max
        precondition(bounded.fraction == 1, "Reported counts beyond the window cannot overflow the bar")
        precondition(bounded.contextSegments == [1])
        var split = value
        split.contextUsed = 100
        split.contextWindow = 200
        split.contextBreakdown = .init(input: 20, cacheRead: 70, cacheWrite: 10)
        precondition(split.contextSegments == [0.1, 0.35, 0.05], "Prompt categories occupy their share of capacity, not the entire bar")
        split.contextBreakdown = .init(input: .max, cacheRead: .max, cacheWrite: 10)
        precondition(split.contextSegments == [0.5], "Invalid breakdowns cannot overflow or invent categories")
        split.contextWindow = nil
        precondition(split.contextSegments.isEmpty, "Unknown capacity cannot display a percentage bar")
        print("Chat inspection: agent/configuration distinction, unknown telemetry, and bounded rendering passed")
    }
}
