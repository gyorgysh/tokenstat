// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Foundation

/// The job session owns selection and observation. Its service owns transport,
/// allowing the same screens to be exercised without an account or live work.
protocol ClientJobService: Sendable {
    func automations(peer: String) async throws -> [Automation]
    func automationRuns(peer: String) async throws -> [RunRecord]
    func createAutomation(peer: String, job: Automation) async throws -> Automation
    func updateAutomation(peer: String, job: Automation) async throws -> Automation
    func removeAutomation(peer: String, id: String) async throws
    func automationBackends(peer: String) async throws -> [AgentBackend]
    func automationQueue(peer: String) async throws -> AutomationQueue
    func runAutomation(peer: String, id: String) async throws -> Automation
    func setAutomation(peer: String, id: String, enabled: Bool) async throws -> Automation
    func killAutomation(peer: String, runID: String) async throws
    func automationTranscript(peer: String, id: String, offset: UInt64) async throws -> TranscriptChunk
    func workflows(peer: String) async throws -> [WorkflowGraph]
    func workflowRuns(peer: String) async throws -> [WorkflowRunRecord]
    func runWorkflow(peer: String, id: String, input: String, workspaceID: String) async throws -> WorkflowRunRecord
    func updateWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph
    func killWorkflow(peer: String, runID: String) async throws
    func continueWorkflow(peer: String, runID: String) async throws -> WorkflowRunRecord
    func workflowTranscript(peer: String, runID: String, nodeID: String, offset: UInt64) async throws -> TranscriptChunk
}

struct ClientRemoteJobService: ClientJobService {
    func automations(peer: String) async throws -> [Automation] {
        try await ClientRemote.automations(peer: peer)
    }
    func automationRuns(peer: String) async throws -> [RunRecord] {
        try await ClientRemote.automationRuns(peer: peer)
    }
    func createAutomation(peer: String, job: Automation) async throws -> Automation {
        try await ClientRemote.createAutomation(peer: peer, job: job)
    }
    func updateAutomation(peer: String, job: Automation) async throws -> Automation {
        try await ClientRemote.updateAutomation(peer: peer, job: job)
    }
    func removeAutomation(peer: String, id: String) async throws {
        try await ClientRemote.removeAutomation(peer: peer, id: id)
    }
    func automationBackends(peer: String) async throws -> [AgentBackend] {
        try await ClientRemote.automationBackends(peer: peer)
    }
    func automationQueue(peer: String) async throws -> AutomationQueue {
        try await ClientRemote.automationQueue(peer: peer)
    }
    func runAutomation(peer: String, id: String) async throws -> Automation {
        try await ClientRemote.runAutomation(peer: peer, id: id)
    }
    func setAutomation(peer: String, id: String, enabled: Bool) async throws -> Automation {
        try await ClientRemote.setAutomation(peer: peer, id: id, enabled: enabled)
    }
    func killAutomation(peer: String, runID: String) async throws {
        try await ClientRemote.killAutomation(peer: peer, runID: runID)
    }
    func automationTranscript(peer: String, id: String, offset: UInt64) async throws -> TranscriptChunk {
        try await ClientRemote.automationTranscript(peer: peer, id: id, offset: offset)
    }
    func workflows(peer: String) async throws -> [WorkflowGraph] {
        try await ClientRemote.workflows(peer: peer)
    }
    func workflowRuns(peer: String) async throws -> [WorkflowRunRecord] {
        try await ClientRemote.workflowRuns(peer: peer)
    }
    func runWorkflow(peer: String, id: String, input: String, workspaceID: String) async throws -> WorkflowRunRecord {
        try await ClientRemote.runWorkflow(peer: peer, id: id, input: input, workspaceID: workspaceID)
    }
    func updateWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph {
        try await ClientRemote.updateWorkflow(peer: peer, graph: graph)
    }
    func killWorkflow(peer: String, runID: String) async throws {
        try await ClientRemote.killWorkflow(peer: peer, runID: runID)
    }
    func continueWorkflow(peer: String, runID: String) async throws -> WorkflowRunRecord {
        try await ClientRemote.continueWorkflow(peer: peer, runID: runID)
    }
    func workflowTranscript(peer: String, runID: String, nodeID: String, offset: UInt64) async throws -> TranscriptChunk {
        try await ClientRemote.workflowTranscript(peer: peer, runID: runID, nodeID: nodeID, offset: offset)
    }
}
#endif
