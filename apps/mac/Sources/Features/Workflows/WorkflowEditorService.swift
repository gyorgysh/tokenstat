// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

protocol WorkflowEditorService: Sendable {
    func createWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph
    func updateWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph
    func removeWorkflow(id: String) async throws
    func workflow(id: String) async throws -> WorkflowGraph?
    func workflows() async throws -> [WorkflowGraph]
    func automationBackends() async throws -> [AgentBackend]
    func automations() async throws -> [Automation]
    func automationQueue() async throws -> AutomationQueue
    func liveWorkflowIDs() async throws -> [String]
}

extension WorkflowEditorService {
    func workflow(id: String) async throws -> WorkflowGraph? {
        try await workflows().first { $0.id == id }
    }

    func automations() async throws -> [Automation] { [] }
    func liveWorkflowIDs() async throws -> [String] { [] }
}

/// One computer. Mobile always has a peer. Mac local uses the daemon.
struct WorkflowEditorTarget: Hashable, Sendable, WorkflowEditorService {
    let peer: String?

    func createWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph {
        if let peer {
            return try await Bridge.onPeer(
                peer,
                "workflow.create",
                ["workflow": try encode(graph)],
                as: WorkflowGraph.self
            )
        }
        #if os(macOS)
        return try await Bridge.createWorkflow(graph)
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func updateWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph {
        if let peer {
            return try await Bridge.onPeer(
                peer,
                "workflow.update",
                ["workflow": try encode(graph)],
                as: WorkflowGraph.self
            )
        }
        #if os(macOS)
        return try await Bridge.updateWorkflow(graph)
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func removeWorkflow(id: String) async throws {
        struct Removed: Codable, Sendable { let removed: Bool? }
        if let peer {
            _ = try await Bridge.onPeer(peer, "workflow.remove", ["id": id], as: Removed.self)
            return
        }
        #if os(macOS)
        try await Bridge.removeWorkflow(id)
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func workflows() async throws -> [WorkflowGraph] {
        if let peer {
            return try await Bridge.onPeer(peer, "workflow.list", [:], as: [WorkflowGraph].self)
        }
        #if os(macOS)
        return try await Bridge.workflows()
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func automationBackends() async throws -> [AgentBackend] {
        if let peer {
            return try await Bridge.onPeer(peer, "automation.backends", [:], as: [AgentBackend].self)
        }
        #if os(macOS)
        return try await Bridge.automationBackends()
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func automations() async throws -> [Automation] {
        if let peer {
            return try await Bridge.onPeer(peer, "automation.list", [:], as: [Automation].self)
        }
        #if os(macOS)
        return try await Bridge.automations()
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func automationQueue() async throws -> AutomationQueue {
        if let peer {
            return try await Bridge.onPeer(peer, "automation.queue", [:], as: AutomationQueue.self)
        }
        #if os(macOS)
        return try await Bridge.automationQueue()
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }

    func liveWorkflowIDs() async throws -> [String] {
        let runs: [WorkflowRunRecord]
        if let peer {
            runs = try await Bridge.onPeer(peer, "workflow.runs", [:], as: [WorkflowRunRecord].self)
        } else {
            #if os(macOS)
            runs = try await Bridge.workflowRuns()
            #else
            throw CocoaError(.fileReadNoSuchFile)
            #endif
        }
        return Array(Set(runs.filter(\.isLive).map(\.workflowID)))
    }

    private func encode(_ graph: WorkflowGraph) throws -> [String: Any] {
        let data = try JSONEncoder().encode(graph)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw WorkflowEditorDraft.Invalid.fields("Could not encode this workflow.")
        }
        return dict
    }
}
