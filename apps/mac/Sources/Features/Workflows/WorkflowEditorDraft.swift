// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Graph metadata a phone or iPad can author before node editing exists.
///
/// Recipes fill nodes and edges locally. They do not call Design. A blank
/// draft is a Start card. Folder stays the workspace this editor opened in.
struct WorkflowEditorDraft: Codable, Equatable, Sendable, JobScheduleEditing, JobBudgetEditing {
    enum Invalid: LocalizedError {
        case fields(String)
        var errorDescription: String? { switch self { case let .fields(message): message } }
    }

    static let blankStarterID = "blank"

    var name: String
    var workspaceID: String
    var starterID: String
    var enabled: Bool
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
    var scheduleKind: ScheduleKind
    var intervalMinutes: String
    var intervalSeconds: UInt64
    var intervalTouched: Bool
    var hour: Int
    var minute: Int
    var weekday: Int
    var weeklyDays: Int
    var weeklyDayEdited: Bool
    var customDays: Int
    var budgetMinutes: String
    var noTimeLimit: Bool

    enum CodingKeys: String, CodingKey {
        case name, starterID = "starterId", enabled, nodes, edges, scheduleKind
        case intervalMinutes, intervalSeconds, intervalTouched, hour, minute
        case weekday, weeklyDays, weeklyDayEdited, customDays, budgetMinutes, noTimeLimit
        case workspaceID = "workspaceId"
    }

    init(workspaceID: String, budgetSeconds: UInt64 = 10_800) {
        name = ""
        self.workspaceID = workspaceID
        starterID = Self.blankStarterID
        enabled = true
        nodes = Self.blankNodes
        edges = []
        scheduleKind = .once
        intervalMinutes = "60"
        intervalSeconds = 0
        intervalTouched = false
        hour = 9
        minute = 0
        weekday = 0
        weeklyDays = 0
        weeklyDayEdited = false
        customDays = AutomationSchedule.weekdaysMask
        noTimeLimit = budgetSeconds == 0
        budgetMinutes = noTimeLimit ? "180" : String(max(1, budgetSeconds / 60))
    }

    init(_ graph: WorkflowGraph) {
        name = graph.name
        workspaceID = graph.workspaceID ?? ""
        starterID = ""
        enabled = graph.enabled
        nodes = graph.nodes
        edges = graph.edges
        scheduleKind = .once
        intervalMinutes = "60"
        intervalSeconds = 0
        intervalTouched = false
        hour = 9
        minute = 0
        weekday = 0
        weeklyDays = 0
        weeklyDayEdited = false
        customDays = AutomationSchedule.weekdaysMask
        budgetMinutes = "180"
        noTimeLimit = false
        loadSchedule(graph.schedule)
        loadBudget(seconds: graph.budgetSeconds)
    }

    static var blankNodes: [WorkflowNode] {
        [WorkflowNode(id: "in", kind: .input, x: 80, y: 120, title: "Start")]
    }

    var isBlankStarter: Bool { starterID == Self.blankStarterID }

    mutating func applyBlank() {
        starterID = Self.blankStarterID
        nodes = Self.blankNodes
        edges = []
    }

    mutating func applyRecipe(_ recipe: WorkflowRecipe) {
        starterID = recipe.id
        nodes = recipe.nodes
        edges = recipe.edges
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Untitled" {
            name = recipe.name
        }
    }

    var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this workflow a name."
        }
        if name.utf8.count > 4096 {
            return "Shorten the name to 4 KiB or less."
        }
        if workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a folder for this workflow."
        }
        if nodes.isEmpty {
            return "A workflow needs a Start step."
        }
        var seen = Set<String>()
        for node in nodes {
            let id = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { return "Every step needs an id." }
            if !seen.insert(id).inserted { return "Two steps share the id \(id)." }
        }
        if let scheduleValidation { return scheduleValidation }
        if let budgetValidation { return budgetValidation }
        return nil
    }

    func matches(_ graph: WorkflowGraph) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) == graph.name
            && workspaceID == (graph.workspaceID ?? "")
            && builtSchedule == graph.schedule
            && budgetSeconds == graph.budgetSeconds
            && (builtSchedule.repeats ? enabled : false) == graph.enabled
            && nodes == graph.nodes
            && edges == graph.edges
    }

    func makeGraph(
        id: String,
        lastRunAtMs: Int64? = nil,
        lastRunID: String? = nil
    ) throws -> WorkflowGraph {
        guard validation == nil, let budgetSeconds else {
            throw Invalid.fields(validation ?? "Check this workflow's settings.")
        }
        var graph = WorkflowGraph(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: .workspace,
            workspaceID: workspaceID,
            budgetSeconds: budgetSeconds,
            schedule: builtSchedule,
            enabled: builtSchedule.repeats ? enabled : false,
            nodes: nodes,
            edges: edges,
            lastRunAtMs: lastRunAtMs,
            lastRunID: lastRunID
        )
        graph.layoutIfNeeded()
        return graph
    }
}
