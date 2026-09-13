// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Working copy of a workflow graph: nodes, edges, selection and undo.
///
/// Mac's canvas and the phone/iPad step editor share this. It does not
/// talk to the host. Save still goes through the existing create/update
/// path. Identities stay stable: new steps are `n{n}`, edges are
/// `from>to:when`.
struct WorkflowGraphDocument {
    private struct Snapshot {
        var graph: WorkflowGraph
        var selectedNodeID: String?
        var selectedEdgeID: String?
    }

    private var current: Snapshot?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var groupingEdits = false
    private(set) var isDirty = false

    var isOpen: Bool { current != nil }
    var graph: WorkflowGraph? { current?.graph }
    var selectedNodeID: String? { current?.selectedNodeID }
    var selectedEdgeID: String? { current?.selectedEdgeID }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedNode: WorkflowNode? {
        guard let id = selectedNodeID, let graph else { return nil }
        return graph.nodes.first { $0.id == id }
    }

    var selectedEdge: WorkflowEdge? {
        guard let id = selectedEdgeID, let graph else { return nil }
        return graph.edges.first { $0.id == id }
    }

    var stepsIssue: String? { graph?.stepsIssue }

    /// Layout, select the first step, and start a clean undo history.
    mutating func open(_ graph: WorkflowGraph, dirty: Bool) {
        var laid = graph
        laid.layoutIfNeeded()
        current = Snapshot(
            graph: laid,
            selectedNodeID: laid.nodes.first?.id,
            selectedEdgeID: nil
        )
        undoStack = []
        redoStack = []
        groupingEdits = false
        isDirty = dirty
    }

    mutating func close() {
        current = nil
        undoStack = []
        redoStack = []
        groupingEdits = false
        isDirty = false
    }

    /// Host just wrote this graph. Keep undo so a person can still go back.
    mutating func markSaved(_ graph: WorkflowGraph) {
        guard var snapshot = current else { return }
        var laid = graph
        laid.layoutIfNeeded()
        if let id = snapshot.selectedNodeID, !laid.nodes.contains(where: { $0.id == id }) {
            snapshot.selectedNodeID = laid.nodes.first?.id
        }
        if let id = snapshot.selectedEdgeID, !laid.edges.contains(where: { $0.id == id }) {
            snapshot.selectedEdgeID = nil
        }
        snapshot.graph = laid
        current = snapshot
        isDirty = false
    }

    /// Fresh copy from the host while this editor has no local edits.
    mutating func reloadClean(_ graph: WorkflowGraph) {
        guard isOpen, !isDirty else { return }
        var laid = graph
        laid.layoutIfNeeded()
        var snapshot = current ?? Snapshot(graph: laid, selectedNodeID: laid.nodes.first?.id, selectedEdgeID: nil)
        if let id = snapshot.selectedNodeID, !laid.nodes.contains(where: { $0.id == id }) {
            snapshot.selectedNodeID = laid.nodes.first?.id
        }
        snapshot.graph = laid
        current = snapshot
    }

    mutating func selectNode(_ id: String?) {
        endGroupedEdit()
        guard var snapshot = current else { return }
        snapshot.selectedNodeID = id
        snapshot.selectedEdgeID = nil
        current = snapshot
    }

    mutating func selectEdge(_ id: String?) {
        endGroupedEdit()
        guard var snapshot = current else { return }
        snapshot.selectedEdgeID = id
        if id != nil {
            snapshot.selectedNodeID = nil
        }
        current = snapshot
    }

    mutating func mutate(_ body: (inout WorkflowGraph) -> Void) {
        endGroupedEdit()
        guard var snapshot = current else { return }
        pushUndo(snapshot)
        body(&snapshot.graph)
        current = snapshot
        isDirty = true
    }

    /// Write without a new undo. Pair with `beginGroupedEdit`.
    mutating func writeWorking(_ body: (inout WorkflowGraph) -> Void) {
        guard var snapshot = current else { return }
        body(&snapshot.graph)
        current = snapshot
        isDirty = true
    }

    mutating func beginGroupedEdit() {
        guard !groupingEdits, let snapshot = current else { return }
        pushUndo(snapshot)
        groupingEdits = true
    }

    mutating func endGroupedEdit() {
        groupingEdits = false
    }

    mutating func undo() {
        endGroupedEdit()
        guard let current, let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        self.current = previous
        isDirty = true
    }

    mutating func redo() {
        endGroupedEdit()
        guard let current, let next = redoStack.popLast() else { return }
        undoStack.append(current)
        self.current = next
        isDirty = true
    }

    mutating func addNode(kind: WorkflowNodeKind, backend: String? = nil, automationID: String? = nil) {
        guard let graph else { return }
        if WorkflowGraphRules.additionIssue(kind: kind, nodeCount: graph.nodes.count) != nil {
            return
        }
        let sourceID = selectedNodeID
        var created: String?
        mutate { graph in
            let id = WorkflowGraphRules.nextNodeID(in: graph.nodes)
            created = id
            let origin = WorkflowGraphRules.origin(in: graph.nodes, under: sourceID)
            graph.nodes.append(
                WorkflowGraphRules.makeNode(
                    kind: kind,
                    id: id,
                    x: origin.x,
                    y: origin.y,
                    backend: backend,
                    automationID: automationID
                )
            )
            if let sourceID, sourceID != id, graph.nodes.contains(where: { $0.id == sourceID }) {
                graph.edges.removeAll { $0.from == sourceID && $0.to == id }
                graph.edges.append(WorkflowEdge(from: sourceID, to: id, when: .ok))
            }
        }
        guard var snapshot = current, let created else { return }
        snapshot.selectedNodeID = created
        snapshot.selectedEdgeID = nil
        current = snapshot
    }

    mutating func beginNodeMove() {
        guard let current else { return }
        pushUndo(current)
    }

    /// Live drag. Undo was captured at `beginNodeMove`.
    mutating func moveNode(id: String, x: Double, y: Double) {
        guard var snapshot = current else { return }
        guard let idx = snapshot.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        snapshot.graph.nodes[idx].x = x
        snapshot.graph.nodes[idx].y = y
        current = snapshot
        isDirty = true
    }

    mutating func connect(from: String, to: String, when: WorkflowEdgeWhen) {
        guard let graph else { return }
        if WorkflowGraphRules.connectionIssue(from: from, to: to, nodes: graph.nodes, edges: graph.edges) != nil {
            return
        }
        mutate { graph in
            graph.edges.removeAll { $0.from == from && $0.to == to }
            graph.edges.append(WorkflowEdge(from: from, to: to, when: when))
        }
    }

    mutating func deleteSelection() {
        if let edgeID = selectedEdgeID {
            mutate { graph in
                graph.edges.removeAll { $0.id == edgeID }
            }
            guard var snapshot = current else { return }
            snapshot.selectedEdgeID = nil
            current = snapshot
            return
        }
        guard let nodeID = selectedNodeID else { return }
        mutate { graph in
            graph.nodes.removeAll { $0.id == nodeID }
            graph.edges.removeAll { $0.from == nodeID || $0.to == nodeID }
        }
        guard var snapshot = current else { return }
        snapshot.selectedNodeID = snapshot.graph.nodes.first?.id
        snapshot.selectedEdgeID = nil
        current = snapshot
    }

    mutating func updateNode(id: String, _ body: (inout WorkflowNode) -> Void) {
        mutate { graph in
            if let idx = graph.nodes.firstIndex(where: { $0.id == id }) {
                body(&graph.nodes[idx])
            }
        }
    }

    mutating func updateSelectedNode(_ body: (inout WorkflowNode) -> Void) {
        guard let id = selectedNodeID else { return }
        updateNode(id: id, body)
    }

    mutating func updateSelectedEdge(when: WorkflowEdgeWhen) {
        guard let id = selectedEdgeID else { return }
        var updated: String?
        mutate { graph in
            if let idx = graph.edges.firstIndex(where: { $0.id == id }) {
                graph.edges[idx].when = when
                updated = graph.edges[idx].id
            }
        }
        guard var snapshot = current, let updated else { return }
        snapshot.selectedEdgeID = updated
        current = snapshot
    }

    mutating func replaceSteps(nodes: [WorkflowNode], edges: [WorkflowEdge], nameIfUntitled: String? = nil) {
        mutate { graph in
            graph.nodes = nodes
            graph.edges = edges
            let name = graph.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let nameIfUntitled, name.isEmpty || name == "Untitled" {
                graph.name = nameIfUntitled
            }
            graph.layoutIfNeeded()
        }
        guard var snapshot = current else { return }
        snapshot.selectedNodeID = snapshot.graph.nodes.first?.id
        snapshot.selectedEdgeID = nil
        current = snapshot
    }

    mutating func rename(_ name: String) {
        mutate { $0.name = name }
    }

    mutating func setScope(_ scope: WorkflowScope, workspaceID: String?) {
        mutate { graph in
            graph.scope = scope
            graph.workspaceID = scope == .workspace ? workspaceID : nil
        }
    }

    mutating func setBudgetMinutes(_ minutes: UInt64) {
        let capped = min(minutes, UInt64.max / 60)
        mutate { $0.budgetSeconds = capped * 60 }
    }

    private mutating func pushUndo(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > WorkflowGraphRules.undoLimit {
            undoStack.removeFirst(undoStack.count - WorkflowGraphRules.undoLimit)
        }
        redoStack.removeAll()
    }
}
