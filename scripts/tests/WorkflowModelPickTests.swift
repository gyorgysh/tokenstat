// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkflowModelPick.swift.
import Foundation

struct AgentBackend { let id: String }

@main struct WorkflowModelPickTests {
    static func main() {
        let codex = AgentBackend(id: "codex")
        let claude = AgentBackend(id: "claude")
        let opencode = AgentBackend(id: "opencode")
        for backend in [codex, claude] {
            assert(WorkflowModelPick.buildAgent(from: [backend], used: [backend.id])?.id == backend.id,
                   "A single-agent recipe must still implement the plan")
        }
        assert(WorkflowModelPick.buildAgent(from: [opencode, codex], used: ["opencode"])?.id == "codex",
               "An already-used preferred backend must not hide an unused implementation agent")
        assert(WorkflowModelPick.buildAgent(from: [opencode, claude], used: ["opencode"])?.id == "claude")
        assert(WorkflowModelPick.buildAgent(from: [], used: []) == nil)
        print("Workflow model picks: single-agent implementation and unused-agent priority passed")
    }
}
