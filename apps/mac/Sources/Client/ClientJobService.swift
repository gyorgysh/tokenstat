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
    func supportsAutomationReceipts(peer: String) async -> Bool
    func editAutomation(peer: String, job: Automation, revision: UInt64) async throws -> Automation
    func createAutomationOnce(peer: String, job: Automation, operationID: String) async throws -> AutomationCreationOutcome
    func automationCreationReceipt(peer: String, operationID: String) async throws -> AutomationCreationOutcome?
    func runAutomationOnce(peer: String, id: String, operationID: String) async throws -> AutomationRunOutcome
    func automationRunReceipt(peer: String, operationID: String) async throws -> AutomationRunOutcome?
    func removeAutomation(peer: String, id: String) async throws
    func automationBackends(peer: String) async throws -> [AgentBackend]
    func automationQueue(peer: String) async throws -> AutomationQueue
    func setAutomationQueue(
        peer: String,
        defaultBudgetSeconds: UInt64,
        maxConcurrent: UInt32
    ) async throws -> AutomationQueue
    func runAutomation(peer: String, id: String) async throws -> Automation
    func setAutomation(peer: String, id: String, enabled: Bool) async throws -> Automation
    func killAutomation(peer: String, runID: String) async throws
    func automationTranscript(peer: String, id: String, offset: UInt64) async throws -> TranscriptChunk
    func workflows(peer: String) async throws -> [WorkflowGraph]
    func workflowRuns(peer: String) async throws -> [WorkflowRunRecord]
    func runWorkflow(peer: String, id: String, input: String, workspaceID: String) async throws -> WorkflowRunRecord
    func createWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph
    func updateWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph
    func removeWorkflow(peer: String, id: String) async throws
    func killWorkflow(peer: String, runID: String) async throws
    func continueWorkflow(peer: String, runID: String) async throws -> WorkflowRunRecord
    func workflowTranscript(peer: String, runID: String, nodeID: String, offset: UInt64) async throws -> TranscriptChunk
}

extension ClientJobService {
    func supportsAutomationReceipts(peer: String) async -> Bool { false }
    func editAutomation(peer: String, job: Automation, revision: UInt64) async throws -> Automation {
        try await updateAutomation(peer: peer, job: job)
    }
    func createAutomationOnce(peer: String, job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        let created = try await createAutomation(peer: peer, job: job)
        return AutomationCreationOutcome(operationID: operationID, jobID: created.id, createdAtMs: 0, job: created)
    }
    func automationCreationReceipt(peer: String, operationID: String) async throws -> AutomationCreationOutcome? { nil }
    func runAutomationOnce(peer: String, id: String, operationID: String) async throws -> AutomationRunOutcome {
        let job = try await runAutomation(peer: peer, id: id)
        return AutomationRunOutcome(
            operationID: operationID,
            jobID: id,
            runID: job.lastRunID ?? "",
            createdAtMs: 0,
            job: job,
            run: nil
        )
    }
    func automationRunReceipt(peer: String, operationID: String) async throws -> AutomationRunOutcome? { nil }
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
    func supportsAutomationReceipts(peer: String) async -> Bool {
        await RemoteHostFeature.automationReceipts.isSupported(peer: peer)
    }
    func editAutomation(peer: String, job: Automation, revision: UInt64) async throws -> Automation {
        try await ClientRemote.editAutomation(peer: peer, job: job, revision: revision)
    }
    func createAutomationOnce(peer: String, job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        try await ClientRemote.createAutomationOnce(peer: peer, job: job, operationID: operationID)
    }
    func automationCreationReceipt(peer: String, operationID: String) async throws -> AutomationCreationOutcome? {
        try await ClientRemote.automationCreationReceipt(peer: peer, operationID: operationID)
    }
    func runAutomationOnce(peer: String, id: String, operationID: String) async throws -> AutomationRunOutcome {
        try await ClientRemote.runAutomationOnce(peer: peer, id: id, operationID: operationID)
    }
    func automationRunReceipt(peer: String, operationID: String) async throws -> AutomationRunOutcome? {
        try await ClientRemote.automationRunReceipt(peer: peer, operationID: operationID)
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
    func setAutomationQueue(
        peer: String,
        defaultBudgetSeconds: UInt64,
        maxConcurrent: UInt32
    ) async throws -> AutomationQueue {
        try await ClientRemote.setAutomationQueue(
            peer: peer,
            defaultBudgetSeconds: defaultBudgetSeconds,
            maxConcurrent: maxConcurrent
        )
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
    func createWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph {
        try await ClientRemote.createWorkflow(peer: peer, graph: graph)
    }
    func updateWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph {
        try await ClientRemote.updateWorkflow(peer: peer, graph: graph)
    }
    func removeWorkflow(peer: String, id: String) async throws {
        try await ClientRemote.removeWorkflow(peer: peer, id: id)
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

/// Job sessions are folder-scoped. Queue settings are not, so the scheduler
/// sheet talks to this adapter instead of the folder session.
struct ClientJobQueueService: AutomationQueueService {
    let peer: String
    let jobs: any ClientJobService

    func automationQueue() async throws -> AutomationQueue {
        try await jobs.automationQueue(peer: peer)
    }

    func setAutomationQueue(
        defaultBudgetSeconds: UInt64,
        maxConcurrent: UInt32
    ) async throws -> AutomationQueue {
        try await jobs.setAutomationQueue(
            peer: peer,
            defaultBudgetSeconds: defaultBudgetSeconds,
            maxConcurrent: maxConcurrent
        )
    }

    func runningJobCount() async throws -> Int {
        try await jobs.automationRuns(peer: peer).filter { $0.status == "running" }.count
    }
}
#endif
