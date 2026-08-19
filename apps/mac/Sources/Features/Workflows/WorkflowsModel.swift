// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// How much readable transcript the inspector keeps.
private let transcriptDisplayCap = 256 * 1024

/// Which side of the Workflows inspector is showing.
enum WorkflowFocus: Sendable {
    case none
    case graph
    case run
}

/// Host-owned workflow graphs and the runs they have produced.
///
/// Everything lives in the daemon. The app lists graphs, edits a working
/// copy on the canvas, starts a run, and tails the selected step. Save
/// writes the same IR the runner and MCP already use.
@MainActor
@Observable
final class WorkflowsModel {
    private(set) var graphs: [WorkflowGraph] = []
    /// Which workspace this screen is showing. Nil is every workspace, and a
    /// global scope shows the graphs that are not bound to a folder.
    var scope: String?
    private(set) var runs: [WorkflowRunRecord] = []
    private(set) var backends: [AgentBackend] = []

    /// True once the daemon has been read at least once.
    private(set) var hasLoaded = false

    var errorMessage: String?
    var noticeMessage: String?

    /// Unsaved design. Never auto-run.
    var draft: WorkflowGraph?
    var designTranscript: String = ""
    var isDesigning = false

    /// The graph open on the canvas. A copy until Save.
    private(set) var working: WorkflowGraph?
    private(set) var isDirty = false
    private(set) var selectedNodeID: String?
    private(set) var selectedEdgeID: String?
    /// Automations a node can run. Same list as the Automations screen.
    private(set) var jobs: [Automation] = []
    private var undoStack: [WorkflowGraph] = []
    private var redoStack: [WorkflowGraph] = []
    private let undoLimit = 30
    /// One undo for a run of keystrokes or a live drag. `mutate` ends it.
    private var groupingEdits = false

    var isEditing: Bool { working != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Bumped when the canvas should fit the graph (open, design, revert).
    private(set) var editorEpoch = 0

    private(set) var selectedGraphID: String?
    private(set) var selectedRunID: String?
    private(set) var selectedFocus: WorkflowFocus = .none
    private(set) var selectedStepID: String?
    private(set) var transcriptText: String = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var pollingKey: String?
    private var noticeGeneration = 0
    private var isVisible = false

    func appeared() async {
        isVisible = true
        await load()
        syncWatching()
    }

    func disappeared() {
        isVisible = false
        stopPolling()
    }

    func pickerBackends(keeping id: String? = nil) -> [AgentBackend] {
        backends.visibleForPicker(keeping: id)
    }

    func load() async {
        do {
            async let g = Bridge.workflows()
            async let r = Bridge.workflowRuns()
            async let b = Bridge.automationBackends()
            async let a = Bridge.automations()
            graphs = try await g
            runs = try await r
            #if os(macOS)
            RunNotifications.shared.settle(workflows: runs)
            #endif
            backends = try await b
            jobs = try await a
            hasLoaded = true
            errorMessage = nil
            if let id = working?.id, !id.isEmpty, !isDirty, let fresh = graphs.first(where: { $0.id == id }) {
                working = fresh
            }
            syncWatching()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sidebar and list stay current while this screen is off.
    func refreshList() async {
        do {
            async let g = Bridge.workflows()
            async let r = Bridge.workflowRuns()
            graphs = try await g
            runs = try await r
            #if os(macOS)
            RunNotifications.shared.settle(workflows: runs)
            #endif
        } catch {
            // The next tick tries again.
        }
    }

    func lastRun(for graph: WorkflowGraph) -> WorkflowRunRecord? {
        if let id = graph.lastRunID, let run = runs.first(where: { $0.id == id }) {
            return run
        }
        return runs.first { $0.workflowID == graph.id }
    }

    func runs(of graph: WorkflowGraph) -> [WorkflowRunRecord] {
        runs.filter { $0.workflowID == graph.id }
    }

    /// The graphs of the current scope. The sidebar lists live runs bound
    /// to the folder. A workspace shows graphs bound to it. The global board
    /// shows unbound graphs only.
    var scoped: [WorkflowGraph] {
        guard let scope else { return graphs.filter { $0.scope == .global } }
        return graphs.filter { $0.scope == .workspace && $0.workspaceID == scope }
    }

    /// The runs of the current scope, for the same reason `scoped` exists:
    /// Recent runs sits under a scoped library and has to agree with it.
    var scopedRuns: [WorkflowRunRecord] {
        guard let scope else {
            return runs.filter { run in
                if let graph = graphs.first(where: { $0.id == run.workflowID }) {
                    return graph.scope == .global
                }
                return run.workspaceID.isEmpty
            }
        }
        return runs.filter { $0.workspaceID == scope }
    }

    /// What the sidebar counts: runs in flight, or the graphs waiting to run.
    func count(in workspaceID: String) -> Int {
        let live = liveRuns(in: workspaceID).count
        if live > 0 { return live }
        return graphs.filter { $0.scope == .workspace && $0.workspaceID == workspaceID }.count
    }

    func liveRuns(in workspaceID: String) -> [WorkflowRunRecord] {
        runs.filter { $0.workspaceID == workspaceID && $0.isLive }
    }

    var selectedGraph: WorkflowGraph? {
        if let draft, selectedGraphID == draft.id || (draft.id.isEmpty && selectedFocus == .graph && selectedGraphID == nil) {
            return draft
        }
        guard let selectedGraphID else { return nil }
        return graphs.first { $0.id == selectedGraphID } ?? draft
    }

    var selectedRun: WorkflowRunRecord? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    /// Drop a graph, run or draft the new scope would hide.
    func dropOutOfScopeSelection() {
        if let draft, !graphIsInScope(draft) {
            discardDraft()
        }
        if let id = selectedGraphID, let graph = graphs.first(where: { $0.id == id }),
           !graphIsInScope(graph)
        {
            selectedGraphID = nil
            if selectedFocus == .graph { selectedFocus = .none }
        }
        if let id = selectedRunID, let run = runs.first(where: { $0.id == id }),
           !scopedRuns.contains(where: { $0.id == run.id })
        {
            selectedRunID = nil
            if selectedFocus == .run { selectedFocus = .none }
        }
    }

    private func graphIsInScope(_ graph: WorkflowGraph) -> Bool {
        if let scope {
            return graph.scope == .workspace && graph.workspaceID == scope
        }
        return graph.scope == .global
    }

    var selectedStep: WorkflowStep? {
        guard let selectedStepID, let run = selectedRun else { return nil }
        return run.steps.first { $0.nodeID == selectedStepID }
    }

    func graphs(scope: WorkflowScope, workspaceID: String? = nil) -> [WorkflowGraph] {
        graphs.filter { graph in
            guard graph.scope == scope else { return false }
            if scope == .workspace {
                return graph.workspaceID == workspaceID
            }
            return true
        }
    }

    func selectGraph(_ id: String) {
        selectedGraphID = id
        selectedFocus = .graph
        #if os(macOS)
        if let draft, draft.id == id {
            if working?.id != id {
                if isDirty { closeEditor() }
                openEditor(draft)
            }
        } else if let graph = graphs.first(where: { $0.id == id }) {
            if working?.id != id {
                if isDirty { closeEditor() }
                openEditor(graph)
            }
        }
        #endif
        if let graph = graphs.first(where: { $0.id == id }), let last = lastRun(for: graph) {
            watch(last)
        }
    }

    func selectDraft() {
        selectedGraphID = draft?.id
        selectedFocus = .graph
        #if os(macOS)
        if let draft {
            openEditor(draft)
        }
        #endif
        stopPolling()
    }

    func openEditor(_ graph: WorkflowGraph) {
        endGroupedEdit()
        var laid = graph
        laid.layoutIfNeeded()
        working = laid
        isDirty = graph.id.isEmpty
        selectedNodeID = laid.nodes.first?.id
        selectedEdgeID = nil
        undoStack = []
        redoStack = []
        selectedGraphID = graph.id.isEmpty ? nil : graph.id
        selectedFocus = .graph
        editorEpoch += 1
    }

    func closeEditor() {
        endGroupedEdit()
        if isDirty, let working {
            draft = working
        }
        working = nil
        isDirty = false
        selectedNodeID = nil
        selectedEdgeID = nil
        undoStack = []
        redoStack = []
    }

    /// Drop unsaved edits of a saved graph and reload it. A new draft is discarded.
    func revertWorking() {
        endGroupedEdit()
        guard let id = working?.id, !id.isEmpty, let fresh = graphs.first(where: { $0.id == id }) else {
            discardDraft()
            return
        }
        if draft?.id == id {
            draft = nil
        }
        openEditor(fresh)
        showNotice("Reverted to the last save.")
    }

    var selectedNode: WorkflowNode? {
        guard let selectedNodeID, let working else { return nil }
        return working.nodes.first { $0.id == selectedNodeID }
    }

    func selectNode(_ id: String?) {
        endGroupedEdit()
        selectedNodeID = id
        selectedEdgeID = nil
        selectedFocus = .graph
        if let id {
            selectedStepID = id
            transcriptText = ""
            transcriptOffset = 0
            syncWatching()
        }
    }

    func selectEdge(_ id: String?) {
        endGroupedEdit()
        selectedEdgeID = id
        if id != nil {
            selectedNodeID = nil
        }
    }

    func mutate(_ body: (inout WorkflowGraph) -> Void) {
        endGroupedEdit()
        guard var graph = working else { return }
        pushUndo(graph)
        body(&graph)
        applyWorking(graph)
    }

    /// Write the working copy without a new undo. Pair with `beginGroupedEdit`.
    func writeWorking(_ body: (inout WorkflowGraph) -> Void) {
        guard var graph = working else { return }
        body(&graph)
        applyWorking(graph)
    }

    func beginGroupedEdit() {
        guard !groupingEdits, let working else { return }
        pushUndo(working)
        groupingEdits = true
    }

    func endGroupedEdit() {
        groupingEdits = false
    }

    private func applyWorking(_ graph: WorkflowGraph) {
        working = graph
        isDirty = true
        if let draft, draft.id == graph.id {
            self.draft = graph
        }
    }

    func undo() {
        endGroupedEdit()
        guard let current = working, let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        working = previous
        isDirty = true
        if selectedNodeID != nil, !previous.nodes.contains(where: { $0.id == selectedNodeID }) {
            selectedNodeID = previous.nodes.first?.id
        }
    }

    func redo() {
        endGroupedEdit()
        guard let current = working, let next = redoStack.popLast() else { return }
        undoStack.append(current)
        working = next
        isDirty = true
    }

    private func pushUndo(_ graph: WorkflowGraph) {
        undoStack.append(graph)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
    }

    func addNode(kind: WorkflowNodeKind, backend: String? = nil, automationID: String? = nil) {
        mutate { graph in
            let id = nextNodeID(in: graph)
            let sourceID = selectedNodeID
            let origin = nextNodeOrigin(in: graph, under: sourceID)
            var node = WorkflowNode(id: id, kind: kind, x: origin.x, y: origin.y, title: kind.label)
            node.backend = backend
            node.automationID = automationID
            if kind == .agent {
                node.prompt = "{{input}}"
                node.wait = "exit"
            }
            if kind == .http {
                node.method = "GET"
                node.url = "https://"
            }
            if kind == .command {
                node.command = "echo ok"
            }
            if kind == .condition {
                node.test = "contains"
            }
            if kind == .loop {
                node.times = 3
            }
            graph.nodes.append(node)
            if let sourceID, sourceID != id, graph.nodes.contains(where: { $0.id == sourceID }) {
                graph.edges.removeAll { $0.from == sourceID && $0.to == id }
                graph.edges.append(WorkflowEdge(from: sourceID, to: id, when: .ok))
            }
            selectedNodeID = id
        }
    }

    func beginNodeMove() {
        if let working {
            pushUndo(working)
        }
    }

    /// Live drag. Undo was captured at `beginNodeMove`.
    func moveNode(id: String, x: Double, y: Double) {
        guard var graph = working else { return }
        if let idx = graph.nodes.firstIndex(where: { $0.id == id }) {
            graph.nodes[idx].x = x
            graph.nodes[idx].y = y
            working = graph
            isDirty = true
        }
    }

    func connect(from: String, to: String, when: WorkflowEdgeWhen) {
        guard from != to else { return }
        mutate { graph in
            graph.edges.removeAll { $0.from == from && $0.to == to }
            graph.edges.append(WorkflowEdge(from: from, to: to, when: when))
        }
    }

    func deleteSelection() {
        if let edgeID = selectedEdgeID {
            mutate { graph in
                graph.edges.removeAll { $0.id == edgeID }
            }
            selectedEdgeID = nil
            return
        }
        guard let nodeID = selectedNodeID else { return }
        mutate { graph in
            graph.nodes.removeAll { $0.id == nodeID }
            graph.edges.removeAll { $0.from == nodeID || $0.to == nodeID }
        }
        selectedNodeID = working?.nodes.first?.id
    }

    func updateNode(id: String, _ body: (inout WorkflowNode) -> Void) {
        mutate { graph in
            if let idx = graph.nodes.firstIndex(where: { $0.id == id }) {
                body(&graph.nodes[idx])
            }
        }
    }

    func updateSelectedNode(_ body: (inout WorkflowNode) -> Void) {
        guard let id = selectedNodeID else { return }
        updateNode(id: id, body)
    }

    func updateSelectedEdge(when: WorkflowEdgeWhen) {
        guard let id = selectedEdgeID else { return }
        mutate { graph in
            if let idx = graph.edges.firstIndex(where: { $0.id == id }) {
                graph.edges[idx].when = when
                selectedEdgeID = graph.edges[idx].id
            }
        }
    }

    func renameWorking(_ name: String) {
        mutate { $0.name = name }
    }

    func setWorkingScope(_ scope: WorkflowScope, workspaceID: String?) {
        mutate { graph in
            graph.scope = scope
            graph.workspaceID = scope == .workspace ? workspaceID : nil
        }
    }

    func setWorkingBudgetMinutes(_ minutes: UInt64) {
        mutate { $0.budgetSeconds = minutes * 60 }
    }

    private func nextNodeID(in graph: WorkflowGraph) -> String {
        var n = graph.nodes.count + 1
        var id = "n\(n)"
        let existing = Set(graph.nodes.map(\.id))
        while existing.contains(id) {
            n += 1
            id = "n\(n)"
        }
        return id
    }

    private func nextNodeOrigin(in graph: WorkflowGraph, under id: String?) -> (x: Double, y: Double) {
        if let id, let source = graph.nodes.first(where: { $0.id == id }) {
            return (source.x, source.y + 160)
        }
        guard let last = graph.nodes.max(by: { $0.y < $1.y }) else {
            return (80, 80)
        }
        return (last.x, last.y + 160)
    }

    func selectRun(_ run: WorkflowRunRecord) {
        selectedGraphID = run.workflowID
        selectedFocus = .run
        #if os(macOS)
        if let graph = graphs.first(where: { $0.id == run.workflowID }) {
            if working?.id != graph.id {
                if isDirty { closeEditor() }
                openEditor(graph)
            }
        }
        #endif
        watch(run)
    }

    func selectStep(_ nodeID: String) {
        selectedStepID = nodeID
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    /// True when Library Design or Blank would overwrite a stashed dirty graph.
    var canStartNewDraft: Bool {
        !isDirty && draft == nil
    }

    func startBlank(scope: WorkflowScope = .global, workspaceID: String? = nil) {
        guard canStartNewDraft else {
            errorMessage = "Save or discard the unsaved graph first."
            return
        }
        draft = WorkflowGraph.blank(scope: scope, workspaceID: workspaceID)
        designTranscript = ""
        selectDraft()
        showNotice("Blank draft. Review it, then save. It will not run until you press Run.")
    }

    func discardDraft() {
        endGroupedEdit()
        let editingDraft = working.map { $0.id.isEmpty || $0.id == draft?.id } ?? false
        draft = nil
        designTranscript = ""
        if editingDraft {
            working = nil
            isDirty = false
            selectedNodeID = nil
            selectedEdgeID = nil
            undoStack = []
            redoStack = []
        }
        if selectedFocus == .graph, selectedGraphID == nil || !(graphs.contains { $0.id == selectedGraphID }) {
            selectedFocus = .none
            selectedGraphID = nil
        }
    }

    /// Replace the working graph with a local recipe. Does not call Design
    /// and does not run.
    func applyRecipe(_ recipe: WorkflowRecipe) {
        guard working != nil else { return }
        mutate { graph in
            graph.nodes = recipe.nodes
            graph.edges = recipe.edges
            let name = graph.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "Untitled" {
                graph.name = recipe.name
            }
            graph.layoutIfNeeded()
        }
        selectedNodeID = working?.nodes.first?.id
        selectedEdgeID = nil
        editorEpoch += 1
    }

    func design(prompt: String, workspaceID: String?, backend: String?, model: String? = nil, effort: String? = nil) async {
        let intent = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else {
            errorMessage = "Describe the run first."
            return
        }
        guard canStartNewDraft else {
            errorMessage = "Save or discard the unsaved graph first."
            return
        }
        isDesigning = true
        defer { isDesigning = false }
        do {
            let result = try await Bridge.designWorkflow(
                prompt: intent,
                workspaceID: workspaceID,
                backend: backend,
                model: model,
                effort: effort
            )
            var graph = result.workflow
            graph.id = ""
            draft = graph
            designTranscript = result.transcript
            errorMessage = nil
            selectDraft()
            showNotice("Draft ready. Review it, then save. It will not run until you press Run.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDraft() async {
        await saveWorking()
    }

    func saveWorking() async {
        guard var graph = working ?? draft else { return }
        let name = graph.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "A workflow needs a name."
            return
        }
        graph.name = name
        do {
            let saved: WorkflowGraph
            if graph.id.isEmpty {
                saved = try await Bridge.createWorkflow(graph)
            } else {
                saved = try await Bridge.updateWorkflow(graph)
            }
            draft = nil
            designTranscript = ""
            working = saved
            isDirty = false
            errorMessage = nil
            showNotice("Saved \(saved.name).")
            await load()
            selectedGraphID = saved.id
            selectedFocus = .graph
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ graph: WorkflowGraph) async {
        do {
            _ = try await Bridge.updateWorkflow(graph)
            errorMessage = nil
            showNotice("Saved \(graph.name).")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(_ graph: WorkflowGraph, input: String, workspaceID: String?) async {
        do {
            let started = try await Bridge.runWorkflow(
                id: graph.id,
                input: input,
                workspaceID: workspaceID
            )
            errorMessage = nil
            showNotice("Started \(graph.name).")
            await load()
            if let current = runs.first(where: { $0.id == started.id }) {
                selectRun(current)
            } else {
                selectRun(started)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ run: WorkflowRunRecord) async {
        do {
            try await Bridge.workflowKill(runID: run.id)
            errorMessage = nil
            showNotice("Stopped \(run.name).")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func continueRun(_ run: WorkflowRunRecord) async {
        do {
            let updated = try await Bridge.workflowContinue(runID: run.id)
            errorMessage = nil
            showNotice("Continued \(run.name).")
            await load()
            if let current = runs.first(where: { $0.id == updated.id }) {
                selectRun(current)
            } else {
                selectRun(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ graph: WorkflowGraph) async {
        do {
            try await Bridge.removeWorkflow(graph.id)
            if selectedGraphID == graph.id {
                selectedGraphID = nil
                selectedFocus = .none
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func watch(_ run: WorkflowRunRecord) {
        selectedRunID = run.id
        if selectedStepID == nil || !(run.steps.contains { $0.nodeID == selectedStepID }) {
            selectedStepID = run.currentNodeID ?? run.steps.last?.nodeID
        }
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func syncWatching() {
        guard let run = selectedRun, let stepID = selectedStepID else {
            stopPolling()
            return
        }
        if run.isLive {
            startPolling(runID: run.id, nodeID: stepID)
        } else {
            stopPolling()
            let id = run.id
            let node = stepID
            Task { await self.fetchTranscriptUntilCaughtUp(runID: id, nodeID: node) }
        }
    }

    private func startPolling(runID: String, nodeID: String) {
        guard isVisible else { return }
        let key = "\(runID):\(nodeID)"
        if pollTask != nil, pollingKey == key { return }
        stopPolling()
        pollingKey = key
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchTranscript(runID: runID, nodeID: nodeID, resetIfNeeded: true)
                ticks += 1
                if ticks % 3 == 0 {
                    await self.refreshRuns()
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollingKey = nil
    }

    private func refreshRuns() async {
        do {
            let latest = try await Bridge.workflowRuns()
            let before = runs.first { $0.id == selectedRunID }
            runs = latest
            #if os(macOS)
            RunNotifications.shared.settle(workflows: runs)
            #endif
            let after = runs.first { $0.id == selectedRunID }
            if let before, let after, before.status != after.status, !after.isLive {
                stopPolling()
                if let node = selectedStepID {
                    await fetchTranscriptUntilCaughtUp(runID: after.id, nodeID: node)
                }
            }
        } catch {
            // The next tick tries again.
        }
    }

    private func fetchTranscriptUntilCaughtUp(runID: String, nodeID: String) async {
        var slices = 0
        while slices < 8 {
            slices += 1
            let before = transcriptOffset
            await fetchTranscript(runID: runID, nodeID: nodeID, resetIfNeeded: false)
            if selectedRunID != runID || selectedStepID != nodeID { return }
            if transcriptOffset <= before { return }
            if transcriptText.utf8.count >= transcriptDisplayCap { return }
        }
    }

    private func fetchTranscript(runID: String, nodeID: String, resetIfNeeded: Bool) async {
        if resetIfNeeded, selectedRunID != runID || selectedStepID != nodeID {
            stopPolling()
            return
        }
        do {
            let chunk = try await Bridge.workflowTranscript(runID: runID, nodeID: nodeID, offset: transcriptOffset)
            if selectedRunID != runID || selectedStepID != nodeID { return }
            if chunk.nextOffset < transcriptOffset {
                transcriptText = ""
                transcriptOffset = 0
                let again = try await Bridge.workflowTranscript(runID: runID, nodeID: nodeID, offset: 0)
                transcriptText = Self.capped(again.text)
                transcriptOffset = again.nextOffset
                return
            }
            if !chunk.text.isEmpty {
                transcriptText = Self.capped(transcriptText + chunk.text)
            }
            transcriptOffset = chunk.nextOffset
        } catch {
            // The next tick tries again.
        }
    }

    private func showNotice(_ text: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        noticeMessage = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeMessage = nil
        }
    }

    private static func capped(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > transcriptDisplayCap else { return text }
        var start = bytes.count - transcriptDisplayCap
        while start < bytes.count && bytes[start] & 0b1100_0000 == 0b1000_0000 {
            start += 1
        }
        if let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            start = newline + 1
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}
