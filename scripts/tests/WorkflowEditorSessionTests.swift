// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkflowEditorDraft.swift WorkflowEditorService.swift WorkflowEditorSession.swift
// JobScheduleEditing.swift HostScheduleClock.swift WorkbenchDraftFile.swift
// OriginalFileCoordination.swift WorkReference.swift.
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
    case input, agent, command
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
    var command: String? = nil
    var wait: String? = nil
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
    static func createWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph { throw FixtureError.unexpectedTransport }
    static func updateWorkflow(_ graph: WorkflowGraph) async throws -> WorkflowGraph { throw FixtureError.unexpectedTransport }
    static func removeWorkflow(_ id: String) async throws { throw FixtureError.unexpectedTransport }
    static func workflows() async throws -> [WorkflowGraph] { throw FixtureError.unexpectedTransport }
    static func automationBackends() async throws -> [AgentBackend] { throw FixtureError.unexpectedTransport }
    static func automationQueue() async throws -> AutomationQueue { throw FixtureError.unexpectedTransport }
    static func workflowRuns() async throws -> [WorkflowRunRecord] { throw FixtureError.unexpectedTransport }
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
    func seed(_ graph: WorkflowGraph) { graphs.append(graph) }
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

        print("WorkflowEditorSessionTests passed")
    }
}
