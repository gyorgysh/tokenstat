// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutomationsModel.swift Models.swift JSONValue.swift FileDiff.swift WorkflowLayering.swift
// AutoCommitJob.swift AutomationTemplates.swift HostScheduleClock.swift.
// WorkflowsModel.swift WorkflowGraphDocument.swift WorkflowGraphValidation.swift.
import Foundation
import SwiftUI

// Unrelated UI/cache types are inert. The models and their actual Codable
// implementations, formatting and arithmetic are compiled from production.
enum Theme {
    static let accent = Color.blue, danger = Color.red, secondary = Color.gray
    static let stateIdle = Color.gray, warning = Color.orange
}
struct WorkReference { var itemID: String?; var workspaceID: String }
struct ChatRoutingState: Codable, Sendable, Hashable {}
struct BranchPull: Codable, Sendable, Hashable {}
struct RelayUsage: Codable, Sendable, Hashable {}
struct ChatTimelineEvent: Codable, Sendable, Hashable {}
struct ChatUsageTotals: Codable, Sendable, Equatable {}


extension Array where Element == AgentBackend {
    func visibleForPicker(keeping id: String? = nil) -> [AgentBackend] { self }
    func defaultForPicker(keeping id: String? = nil) -> AgentBackend? { first }
}
@MainActor final class RunNotifications {
    static let shared = RunNotifications()
    func settle(automations: [RunRecord]) {}
    func settle(workflows: [WorkflowRunRecord]) {}
}
enum FixtureError: LocalizedError {
    case conflict
    var errorDescription: String? { "This job changed since you opened it" }
}
@MainActor enum Bridge {
    static var jobs: [Automation] = []
    static var runs: [RunRecord] = []
    static var queue = AutomationQueue(defaultBudgetSeconds: 90, maxConcurrent: 2)
    static var outputs: [String: String] = [:]
    static var delayedID: String?
    static var pendingRead: CheckedContinuation<TranscriptChunk, Never>?
    static var rejectEdit = false
    static var launches = 0
    static func automations() async throws -> [Automation] { jobs }
    static func automationRuns() async throws -> [RunRecord] { runs }
    static func automationBackends() async throws -> [AgentBackend] { [] }
    static func automationQueue() async throws -> AutomationQueue { queue }
    static func setAutomationQueue(defaultBudgetSeconds: UInt64, maxConcurrent: UInt32) async throws -> AutomationQueue {
        queue = AutomationQueue(defaultBudgetSeconds: defaultBudgetSeconds, maxConcurrent: maxConcurrent)
        return queue
    }
    static func createAutomation(_ job: Automation) async throws -> Automation { job }
    static func createAutomationOnce(_ job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        AutomationCreationOutcome(operationID: operationID, jobID: job.id, createdAtMs: 0, job: job)
    }
    static func automationCreationReceipt(operationID: String) async throws -> AutomationCreationOutcome? { nil }
    static func setAutomation(_ id: String, enabled: Bool) async throws -> Automation { jobs[0] }
    static func editAutomation(_ job: Automation, expectedRevision: UInt64) async throws -> Automation {
        if rejectEdit { throw FixtureError.conflict }
        return job
    }
    static func runAutomationOnce(id: String, operationID: String) async throws -> AutomationRunOutcome {
        launches += 1
        return AutomationRunOutcome(operationID: operationID, jobID: id, runID: "run", createdAtMs: 0)
    }
    static func automationRunReceipt(operationID: String) async throws -> AutomationRunOutcome? { nil }
    static func automationKill(runID: String) async throws {}
    static func removeAutomation(_ id: String) async throws {}
    static func automationTranscript(id: String, offset: UInt64) async throws -> TranscriptChunk {
        if id == delayedID {
            delayedID = nil
            return await withCheckedContinuation { pendingRead = $0 }
        }
        let data = Array((outputs[id] ?? "").utf8)
        let start = min(Int(offset), data.count)
        let end = min(start + 64 * 1024, data.count)
        return TranscriptChunk(text: String(decoding: data[start..<end], as: UTF8.self), nextOffset: UInt64(end))
    }
}
struct WorkflowRecipe {
    var name: String
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
}
@MainActor extension Bridge {
    static var graphs: [WorkflowGraph] = []
    static var workflowHistory: [WorkflowRunRecord] = []
    static var holdWorkflowSave = false
    static var workflowSaveWaiter: CheckedContinuation<Void, Never>?
    static var workflowSaves = 0
    static var holdDesign = false
    static var designWaiter: CheckedContinuation<Void, Never>?
    static func workflows() async throws -> [WorkflowGraph] { graphs }
    static func workflowRuns() async throws -> [WorkflowRunRecord] { workflowHistory }
    static func designWorkflow(prompt: String, workspaceID: String?, backend: String?, model: String?, effort: String?) async throws -> WorkflowDesignResult {
        if holdDesign { await withCheckedContinuation { designWaiter = $0 } }
        return WorkflowDesignResult(workflow: graphs[0], transcript: "")
    }
    static func createWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph { graph }
    static func editWorkflow(_ graph: WorkflowGraph, revision: UInt64) async throws -> WorkflowGraph {
        if rejectEdit { throw FixtureError.conflict }
        workflowSaves += 1
        if holdWorkflowSave { await withCheckedContinuation { workflowSaveWaiter = $0 } }
        var saved = graph
        saved.revision = revision + 1
        graphs = [saved]
        return saved
    }
    static func updateWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph { graph }
    static func runWorkflow(id: String, input: String, workspaceID: String?) async throws -> WorkflowRunRecord { workflowHistory[0] }
    static func workflowKill(runID: String) async throws {}
    static func workflowContinue(runID: String) async throws -> WorkflowRunRecord { workflowHistory[0] }
    static func removeWorkflow(_ id: String) async throws {}
    static func workflowTranscript(runID: String, nodeID: String, offset: UInt64) async throws -> TranscriptChunk {
        try await automationTranscript(id: runID + ":" + nodeID, offset: offset)
    }
}
@main struct AutomationsModelTests {
    @MainActor static func main() async throws {
        func run(_ id: String, status: String = "ok") -> RunRecord {
            RunRecord(id: id, jobId: "job", name: "Job", backend: "agent", workspaceID: "folder",
                      startedAtMs: 0, status: status, transcriptPath: "")
        }
        func waitFor(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("Timed out waiting for transcript")
        }
        Bridge.runs = [run("long")]
        Bridge.outputs["long"] = String(repeating: "line of output\n", count: 80_000) + "FINAL OUTPUT"
        let model = AutomationsModel()
        await model.appeared()
        try await waitFor { model.transcriptText.hasSuffix("FINAL OUTPUT") }
        assert(model.transcriptText.utf8.count <= 256 * 1024)
        model.disappeared()

        Bridge.runs = [run("old"), run("new")]
        Bridge.delayedID = "old"
        Bridge.outputs["new"] = "new run only"
        let switching = AutomationsModel()
        await switching.appeared()
        try await waitFor { Bridge.pendingRead != nil }
        switching.selectRun(Bridge.runs[1])
        try await waitFor { switching.transcriptText == "new run only" }
        Bridge.pendingRead?.resume(returning: TranscriptChunk(text: "OLD RUN", nextOffset: 7))
        Bridge.pendingRead = nil
        try await Task.sleep(for: .milliseconds(30))
        assert(switching.transcriptText == "new run only", "late old-run response cannot enter new transcript")
        switching.disappeared()

        let queue = AutomationsModel()
        await queue.load()
        queue.queueMaxConcurrent = "4"
        await queue.saveQueue()
        assert(Bridge.queue.defaultBudgetSeconds == 90, "changing concurrency preserves budget seconds")
        queue.queueBudgetMinutes = "3"
        await queue.load()
        assert(queue.queueBudgetMinutes == "3", "refresh does not overwrite a dirty scheduler")

        Bridge.runs = []
        Bridge.jobs = [AutoCommitJob.job(in: "folder", workspaceName: "Folder", backend: "old", model: nil)]
        Bridge.jobs[0].id = "job"
        Bridge.rejectEdit = true
        let commit = AutomationsModel()
        await commit.load()
        await commit.startAutoCommit(workspaceID: "folder", workspaceName: "Folder", backend: "new", model: nil)
        assert(Bridge.launches == 0, "failed update must not launch old Auto commit settings")
        assert(AutomationsModel.isConcurrentEdit(commit.errorMessage), "refresh must preserve update refusal")
        Bridge.rejectEdit = false
        Bridge.graphs = [WorkflowGraph(id: "graph", name: "Graph", nodes: [WorkflowNode(id: "step", kind: .input)])]
        Bridge.workflowHistory = [try JSONDecoder().decode(WorkflowRunRecord.self, from: Data(#"{"id":"workflow-run","workflowId":"graph","status":"ok","currentNodeId":"step"}"#.utf8))]
        Bridge.outputs["workflow-run:step"] = Bridge.outputs["long"]
        let workflow = WorkflowsModel()
        await workflow.appeared()
        workflow.selectRun(Bridge.workflowHistory[0])
        try await waitFor { workflow.transcriptText.hasSuffix("FINAL OUTPUT") }
        assert(workflow.transcriptText.utf8.count <= 256 * 1024)
        workflow.renameWorking("Edited")
        Bridge.rejectEdit = true
        await workflow.saveWorking()
        assert(AutomationsModel.isConcurrentEdit(workflow.errorMessage), "workflow refresh preserves edit refusal")
        Bridge.rejectEdit = false
        Bridge.holdWorkflowSave = true
        let saving = Task { await workflow.saveWorking() }
        try await waitFor { Bridge.workflowSaveWaiter != nil }
        workflow.renameWorking("New edits while saving")
        await workflow.saveWorking()
        assert(Bridge.workflowSaves == 1, "concurrent Save cannot submit twice")
        Bridge.holdWorkflowSave = false
        Bridge.workflowSaveWaiter?.resume()
        Bridge.workflowSaveWaiter = nil
        await saving.value
        assert(workflow.working?.name == "New edits while saving" && workflow.isDirty,
               "late Save preserves newer edits as dirty")
        assert(workflow.working?.revision == 1, "newer edits use the confirmed revision")
        workflow.disappeared()

        let designing = WorkflowsModel()
        await designing.load()
        Bridge.holdDesign = true
        let proposal = Task { await designing.design(prompt: "Design", workspaceID: nil, backend: nil) }
        try await waitFor { Bridge.designWaiter != nil }
        assert(!designing.canStartNewDraft, "pending design excludes another new draft")
        designing.openEditor(Bridge.graphs[0])
        designing.renameWorking("Current editor")
        Bridge.designWaiter?.resume()
        Bridge.designWaiter = nil
        await proposal.value
        assert(designing.working?.name == "Current editor", "late design cannot replace a newer editor")

        print("AutomationsModel transcript ownership, full catch-up, exact queue and update refusal passed")
    }
}
