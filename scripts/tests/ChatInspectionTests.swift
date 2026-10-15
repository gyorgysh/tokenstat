// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatInspection.swift.
import Foundation

@main struct ChatInspectionTests {
    static func main() throws {
        let wire = Data(#"{"backend":"claude","model":"model","contextUsed":1234,"contextWindow":200000,"contextSource":"lastInput","windowSource":"agent","tools":["Read"],"usedTools":["Read"],"mcpServers":[{"name":"godot-mcp","status":"connected","source":"agent","tools":["scene"]},{"name":"tokenstat-mcp","status":"configured","source":"configuration","tools":null}],"mcpReported":true,"observedAtMs":1,"currentRun":true}"#.utf8)
        let value = try JSONDecoder().decode(ChatInspection.self, from: wire)
        precondition(value.contextUsed == 1234 && value.contextWindow == 200000)
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
