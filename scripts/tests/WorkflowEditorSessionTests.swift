// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkflowEditorDraft.swift WorkflowEditorService.swift WorkflowEditorSession.swift
// JobScheduleEditing.swift HostScheduleClock.swift WorkbenchDraftFile.swift OriginalFileCoordination.swift
// WorkReference.swift WorkflowGraphValidation.swift WorkflowGraphDocument.swift.
import Foundation

enum ScheduleKind: String, Codable, Sendable, Hashable, CaseIterable {
    case once, interval, daily, weekdays, weekly, custom
    var label: String { rawValue }
}

struct AutomationSchedule: Codable, Sendable, Hashable {
    var kind: ScheduleKind
    var everySeconds: UInt64 = 0
    var hour: Int = 9
    var minute: Int = 0
    var weekday: Int = 0
    var weekdays: Int = 0
    static let weekdaysMask = 0b0001_1111
    var summary: String { kind.rawValue }
    var repeats: Bool { kind != .once }
}

enum WorkflowScope: String, Codable, Sendable, Hashable {
    case global, workspace
}

enum WorkflowNodeKind: String, Codable, Sendable, Hashable {
    case input, agent, automation, http, command, gate, condition, loop, mcp
    var label: String { rawValue }
}

enum WorkflowEdgeWhen: String, Codable, Sendable, Hashable {
    case ok, error, always
}

struct WorkflowNode: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: WorkflowNodeKind
    var x: Double = 0
    var y: Double = 0
    var title: String = ""
    var backend: String? = nil
    var model: String? = nil
    var effort: String? = nil
    var prompt: String? = nil
    var wait: String? = nil
    var waitPattern: String? = nil
    var automationID: String? = nil
    var promptOverride: String? = nil
    var method: String? = nil
    var url: String? = nil
    var headers: [String: String]? = nil
    var body: String? = nil
    var command: String? = nil
    var test: String? = nil
    var pattern: String? = nil
    var times: UInt32? = nil
    var until: String? = nil
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.label : trimmed
    }
}

struct WorkflowEdge: Codable, Sendable, Hashable, Identifiable {
    var from: String
    var to: String
    var when: WorkflowEdgeWhen = .ok
    var id: String { "\(from)>\(to):\(when.rawValue)" }
}

struct WorkflowGraph: Codable, Sendable, Hashable, Identifiable {
    var id: String = ""
    var name: String
    var scope: WorkflowScope = .workspace
    var workspaceID: String? = nil
    var budgetSeconds: UInt64 = 10_800
    var schedule: AutomationSchedule = AutomationSchedule(kind: .once)
    var enabled: Bool = false
    var nodes: [WorkflowNode] = []
    var edges: [WorkflowEdge] = []
    var lastRunAtMs: Int64? = nil
    var nextRunAtMs: Int64? = nil
    var lastRunID: String? = nil
    mutating func layoutIfNeeded() {}
}

struct WorkflowRecipe: Identifiable {
    var id: String
    var name: String
    var label: String = ""
    var prompt: String = ""
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
}

enum WorkflowRecipes {
    static func recipes(from backends: [AgentBackend]) -> [WorkflowRecipe] { [] }
    static func designAgents(from backends: [AgentBackend]) -> [AgentBackend] {
        backends.filter { $0.id != "sh" }
    }
    static func defaultBackend(from backends: [AgentBackend]) -> String {
        designAgents(from: backends).first?.id ?? ""
    }
}

struct WorkflowDesignResult: Codable, Sendable {
    var workflow: WorkflowGraph
    var transcript: String
}

struct WorkflowRunRecord: Codable, Sendable {
    var id = ""
    var workflowID = ""
    var isLive = false
}

struct AgentBackend: Codable, Sendable {
    var id: String
    var label: String
    var command: String
    var models: [String] = []
    var efforts: [String] = []
}

struct Automation: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct AutomationQueue: Codable, Sendable {
    var defaultBudgetSeconds: UInt64
    var maxConcurrent: UInt32 = 2
    var timezone: String? = nil
}

enum FixtureError: LocalizedError {
    case disconnected, unexpectedTransport, alreadyExists
    var errorDescription: String? {
        switch self {
        case .disconnected: "disconnected"
        case .unexpectedTransport: "unexpected transport"
        case .alreadyExists: "a workflow with id already exists"
        }
    }
}

enum Bridge {
    static func onPeer<T: Decodable & Sendable>(
        _ peer: String, _ method: String, _ params: [String: Any] = [:], as type: T.Type
    ) async throws -> T { throw FixtureError.unexpectedTransport }
    static func onPeer<T: Decodable & Sendable>(
        _ peer: String, _ method: String, _ params: [String: Any] = [:],
        patience: TimeInterval = 99, as type: T.Type
    ) async throws -> T { throw FixtureError.unexpectedTransport }
    static func createWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph { throw FixtureError.unexpectedTransport }
    static func updateWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph { throw FixtureError.unexpectedTransport }
    static func removeWorkflow(_ id: String) async throws { throw FixtureError.unexpectedTransport }
    static func workflows() async throws -> [WorkflowGraph] { throw FixtureError.unexpectedTransport }
    static func automationBackends() async throws -> [AgentBackend] { throw FixtureError.unexpectedTransport }
    static func automations() async throws -> [Automation] { throw FixtureError.unexpectedTransport }
    static func automationQueue() async throws -> AutomationQueue { throw FixtureError.unexpectedTransport }
    static func workflowRuns() async throws -> [WorkflowRunRecord] { throw FixtureError.unexpectedTransport }
    static func designWorkflow(
        prompt: String, workspaceID: String?, backend: String?,
        model: String? = nil, effort: String? = nil
    ) async throws -> WorkflowDesignResult { throw FixtureError.unexpectedTransport }
}

@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}

actor FixtureWorkflows: WorkflowEditorService {
    var graphs: [WorkflowGraph] = []
    var backends: [AgentBackend] = [AgentBackend(id: "codex", label: "Codex", command: "codex")]
    var queue = AutomationQueue(defaultBudgetSeconds: 121, timezone: "America/New_York")
    var creates = 0
    var updates = 0
    var loseCreateBefore = false
    var loseCreateReply = false
    var running: [String] = []
    var designResult: WorkflowDesignResult? = nil
    var designError: FixtureError? = nil
    var designs = 0

    func createWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph {
        if loseCreateBefore { throw FixtureError.disconnected }
        if graphs.contains(where: { $0.id == graph.id }) {
            throw FixtureError.alreadyExists
        }
        creates += 1
        var created = graph
        if created.id.isEmpty { created.id = "wf-\(creates)" }
        graphs.append(created)
        if loseCreateReply { throw FixtureError.disconnected }
        return created
    }

    func updateWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph {
        updates += 1
        if let index = graphs.firstIndex(where: { $0.id == graph.id }) {
            graphs[index] = graph
        }
        return graph
    }

    func removeWorkflow(id: String) async throws {
        graphs.removeAll { $0.id == id }
    }

    func workflow(id: String) async throws -> WorkflowGraph? {
        graphs.first { $0.id == id }
    }

    func workflows() async throws -> [WorkflowGraph] { graphs }
    func automationBackends() async throws -> [AgentBackend] { backends }
    func automationQueue() async throws -> AutomationQueue { queue }
    func liveWorkflowIDs() async throws -> [String] { running }
    func setCreateFailure(before: Bool = false, after: Bool = false) {
        loseCreateBefore = before
        loseCreateReply = after
    }
    func setDesignError(_ error: FixtureError?) { designError = error }
    func seed(_ graph: WorkflowGraph) { graphs.append(graph) }

    func designWorkflow(prompt: String, backend: String?, model: String?, effort: String?) async throws -> WorkflowDesignResult {
        designs += 1
        if let designError { throw designError }
        if let designResult { return designResult }
        return WorkflowDesignResult(
            workflow: WorkflowGraph(
                id: "",
                name: "Drafted \(prompt)",
                workspaceID: "folder",
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "n2", kind: .command, title: "Do it"),
                ],
                edges: [WorkflowEdge(from: "in", to: "n2")]
            ),
            transcript: "Drafted two steps."
        )
    }
}

@main struct WorkflowEditorSessionTests {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FixtureWorkflows()

        func createSession(existing: WorkflowGraph? = nil) -> WorkflowEditorSession {
            WorkflowEditorSession(
                target: WorkflowEditorTarget(peer: "computer"),
                workspaceID: "folder",
                folderName: "Website",
                existing: existing,
                lockedFolder: true,
                scope: .local(installationID: "fixture"),
                hostIdentity: "computer",
                service: service,
                draftDirectory: directory.appendingPathComponent(UUID().uuidString)
            )
        }

        do {
            var draft = WorkflowEditorDraft(workspaceID: "")
            check(draft.validation == "Give this workflow a name.", "empty name")
            draft.name = "Review"
            check(draft.validation == "Choose a folder for this workflow.", "empty folder")
            draft.workspaceID = "folder"
            check(draft.validation == nil, "blank start is valid")
            draft.scheduleKind = .custom
            draft.customDays = 0
            check(draft.validation == "Pick at least one day for a custom schedule.", "custom days")
            draft.customDays = AutomationSchedule.weekdaysMask
            draft.noTimeLimit = false
            draft.budgetMinutes = "0"
            check(draft.validation == "Enter a positive time limit, or choose No limit.", "budget")
            draft.budgetMinutes = "30"
            check(draft.validation == nil, "valid budget")
            draft.scheduleKind = .once
            let once = try draft.makeGraph(id: "wf-1")
            check(once.enabled == false, "once is not scheduled")
            check(once.nodes.count == 1 && once.nodes[0].id == "in", "blank start node")
            draft.scheduleKind = .daily
            draft.enabled = true
            let daily = try draft.makeGraph(id: "wf-2")
            check(daily.enabled, "repeating can be on")
            check(daily.scope == .workspace, "folder scope")
            check(daily.workspaceID == "folder", "folder id")
        }

        do {
            var draft = WorkflowEditorDraft(workspaceID: "folder")
            draft.name = "Keep this name"
            let recipe = WorkflowRecipe(
                id: "full",
                name: "Plan, build, review",
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "build", kind: .agent, title: "Build", backend: "codex"),
                ],
                edges: [WorkflowEdge(from: "in", to: "build")]
            )
            draft.applyRecipe(recipe)
            check(draft.name == "Keep this name", "named graph keeps its name")
            check(draft.nodes.count == 2, "recipe nodes")
            check(draft.starterID == "full", "recipe starter")
            var untitled = WorkflowEditorDraft(workspaceID: "folder")
            untitled.applyRecipe(recipe)
            check(untitled.name == "Plan, build, review", "recipe names a blank")
            untitled.applyBlank()
            check(untitled.nodes.count == 1 && untitled.starterID == WorkflowEditorDraft.blankStarterID, "blank replaces recipe")
        }

        do {
            let editor = createSession()
            editor.fields.workspaceID = "other"
            await editor.load()
            check(editor.fields.workspaceID == "folder", "folder stays locked")
            check(editor.fields.budgetMinutes == "2", "queue default minutes")
            check(editor.schedulerTimezone == "America/New_York", "host zone")
        }

        do {
            let editor = createSession()
            await editor.load()
            editor.fields.name = "Nightly review"
            editor.fields.scheduleKind = .daily
            editor.fields.enabled = true
            editor.fields.budgetMinutes = "30"
            editor.fields.noTimeLimit = false
            await editor.create()
            check(await service.creates == 1, "first create")
            check(editor.saved.created?.name == "Nightly review", "created name")
            check(editor.saved.created?.id.hasPrefix("wf-") == true, "client id")
            check(editor.saved.created?.enabled == true, "daily starts on")
        }

        do {
            await service.setCreateFailure(before: true)
            let lost = createSession()
            await lost.load()
            lost.fields.name = "Lost create"
            lost.fields.budgetMinutes = "15"
            lost.fields.noTimeLimit = false
            await lost.create()
            check(lost.creating, "pending after lost create")
            check(lost.canRetryCreate, "retry same id")
            check(await service.creates == 1, "lost create did not land")
            await service.setCreateFailure(before: false)
            await lost.retryCreate()
            check(await service.creates == 2, "retry used the same path")
            check(lost.saved.created?.name == "Lost create", "retry created")
            check(lost.saved.pendingID == nil, "pending cleared")
        }

        do {
            await service.setCreateFailure(after: true)
            let reply = createSession()
            await reply.load()
            reply.fields.name = "Lost reply"
            reply.fields.budgetMinutes = "15"
            reply.fields.noTimeLimit = false
            await reply.create()
            check(reply.saved.created?.name == "Lost reply", "lost reply recovered from the stored id")
            check(!reply.creating, "recovery is not pending")
            check(await service.creates == 3, "recovery did not create another")
        }

        do {
            await service.setCreateFailure(before: true)
            let pending = createSession()
            await pending.load()
            pending.fields.name = "Arrived later"
            pending.fields.budgetMinutes = "15"
            pending.fields.noTimeLimit = false
            await pending.create()
            let pendingID = pending.saved.pendingID
            check(pendingID != nil, "pending id kept")
            check(await service.creates == 3, "failed before write")
            await service.setCreateFailure(before: false)
            await service.seed(WorkflowGraph(
                id: pendingID ?? "",
                name: "Arrived later",
                workspaceID: "folder",
                nodes: WorkflowEditorDraft.blankNodes
            ))
            await pending.checkCreated()
            check(pending.saved.created?.id == pendingID, "check found the later graph")
            check(await service.creates == 3, "check did not create another")
        }

        do {
            let existing = WorkflowGraph(
                id: "review",
                name: "Review a change",
                workspaceID: "folder",
                budgetSeconds: 1800,
                schedule: AutomationSchedule(kind: .daily, hour: 9),
                enabled: true,
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "read", kind: .agent, title: "Read", backend: "codex"),
                ],
                edges: [WorkflowEdge(from: "in", to: "read")]
            )
            await service.seed(existing)
            let editor = createSession(existing: existing)
            await editor.load()
            check(!editor.canSave, "unchanged is not dirty")
            editor.fields.name = "Review the diff"
            check(editor.canSave, "rename is dirty")
            await editor.save()
            check(await service.updates == 1, "update called")
            check(editor.saved.baseline?.name == "Review the diff", "saved name")
            check(editor.fields.nodes.count == 2, "edit keeps steps")
        }

        do {
            let editor = createSession()
            await editor.load()
            editor.fields.name = "Steps"
            editor.addStep(kind: .command)
            check(editor.fields.nodes.map(\.id) == ["in", "n2"], "session writes steps")
            check(editor.fields.edges.map(\.id) == ["in>n2:ok"], "session writes edges")
            check(editor.canUndoGraph, "undo is available")
            editor.undoGraph()
            check(editor.fields.nodes.map(\.id) == ["in"], "undo writes fields")
            editor.redoGraph()
            check(editor.fields.nodes.last?.command == "echo ok", "redo restores the command")
            editor.fields.nodes[1].backend = nil
            editor.fields.nodes[1].kind = .agent
            editor.fields.nodes[1].command = nil
            check(editor.fields.validation == "An agent step needs an agent.", "save uses host rules")
        }

        do {
            let editor = createSession()
            await editor.load()
            editor.fields.name = "Branch"
            editor.addStep(kind: .condition)
            editor.addStep(kind: .gate)
            editor.selectStep("n2")
            editor.addStep(kind: .command)
            editor.connectSteps(from: "n2", to: "n4", when: .error)
            let outgoing = editor.fields.edges.filter { $0.from == "n2" }
            check(outgoing.contains { $0.to == "n3" && $0.when == .ok }, "Then stays")
            check(outgoing.contains { $0.to == "n4" && $0.when == .error }, "Else stays")
            check(outgoing.count == 2, "If is not flattened to one next step")
            editor.removeConnection(id: "n2>n4:error")
            check(!editor.fields.edges.contains { $0.id == "n2>n4:error" }, "removed Else")
            editor.selectStep("n3")
            editor.beginGroupedStepEdit()
            editor.writeSelectedStep { $0.title = "A" }
            editor.writeSelectedStep { $0.title = "Ask you" }
            editor.endGroupedStepEdit()
            check(editor.fields.nodes.first { $0.id == "n3" }?.title == "Ask you", "grouped title")
            editor.undoGraph()
            check(editor.fields.nodes.first { $0.id == "n3" }?.title == "gate", "one undo for the title")
        }

        do {
            let editor = createSession()
            await editor.load()
            editor.fields.name = "Drag"
            editor.addStep(kind: .command)
            let id = editor.fields.nodes.last?.id ?? ""
            check(id == "n2", "drag target")
            let before = editor.fields.nodes.first { $0.id == id }
            check(before != nil, "drag target exists")
            editor.beginStepMove()
            editor.moveStep(id: id, x: (before?.x ?? 0) + 40, y: (before?.y ?? 0) + 20)
            let moved = editor.fields.nodes.first { $0.id == id }
            check(moved?.x == (before?.x ?? 0) + 40, "touch drag moves x")
            check(moved?.y == (before?.y ?? 0) + 20, "touch drag moves y")
            check(editor.fields.nodes.first?.id == "in", "drag keeps the other step")
            editor.undoGraph()
            let restored = editor.fields.nodes.first { $0.id == id }
            check(restored?.x == before?.x && restored?.y == before?.y, "one undo for the drag")
        }

        do {
            let editor = createSession()
            await editor.load()
            editor.fields.name = "Retarget"
            editor.addStep(kind: .command)
            editor.selectConnection("in>n2:ok")
            editor.updateSelectedConnection(when: .error)
            check(editor.fields.edges.first?.when == .error, "canvas retargets when")
            check(editor.selectedConnectionID == "in>n2:error", "edge id follows when")
            editor.undoGraph()
            check(editor.fields.edges.first?.when == .ok, "one undo for the retarget")
        }

        do {
            let refused = createSession()
            await refused.load()
            refused.designPrompt = "   "
            refused.design()
            check(await service.designs == 0, "blank prompt never asks the host")
            check(!refused.designing, "refused design is not designing")
        }

        do {
            let before = await service.designs
            let editor = createSession()
            await editor.load()
            check(editor.designBackend == "codex", "design defaults to the agent")
            editor.designPrompt = "Nightly tidy"
            editor.design()
            check(editor.designing, "design starts")
            for _ in 0..<200 {
                if !editor.designing { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(!editor.designing, "design finishes")
            check(await service.designs == before + 1, "one design call")
            check(editor.fields.nodes.map(\.id) == ["in", "n2"], "designed steps replace blank")
            check(editor.fields.edges.map(\.id) == ["in>n2:ok"], "designed connections")
            check(editor.fields.starterID == "designed", "starter names the described draft")
            check(editor.fields.name == "Drafted Nightly tidy", "blank name adopts the draft")
            check(editor.designTranscript == "Drafted two steps.", "transcript kept")
            check(editor.designPrompt == "Nightly tidy", "prompt kept for retry")
        }

        do {
            let before = await service.designs
            await service.setDesignError(FixtureError.disconnected)
            let failed = createSession()
            await failed.load()
            failed.designPrompt = "Lost draft"
            failed.design()
            for _ in 0..<200 {
                if !failed.designing { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(await service.designs == before + 1, "failed design still asked once")
            check(failed.errorMessage != nil, "lost design says so")
            check(failed.designPrompt == "Lost draft", "prompt survives a lost design")
            check(failed.fields.nodes.map(\.id) == ["in"], "failed design keeps prior steps")
            check(failed.designTranscript.isEmpty, "no transcript without a draft")
            await service.setDesignError(nil)
            failed.design()
            for _ in 0..<200 {
                if !failed.designing { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(failed.fields.nodes.map(\.id) == ["in", "n2"], "retry drafts with the same prompt")
        }

        do {
            let before = await service.designs
            let existing = WorkflowGraph(
                id: "review",
                name: "Review a change",
                workspaceID: "folder",
                nodes: [WorkflowNode(id: "in", kind: .input, title: "Start")]
            )
            let editor = createSession(existing: existing)
            await editor.load()
            editor.designPrompt = "Not a new graph"
            editor.design()
            check(await service.designs == before, "design is for new graphs only")
            check(!editor.designing, "edit flow never designs")
        }

        print("WorkflowEditorSessionTests passed")
    }
}
