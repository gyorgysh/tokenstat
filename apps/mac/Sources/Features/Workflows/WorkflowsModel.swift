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
    private var document = WorkflowGraphDocument()
    /// Automations a node can run. Same list as the Automations screen.
    private(set) var jobs: [Automation] = []

    var working: WorkflowGraph? { document.graph }
    var isDirty: Bool { document.isDirty }
    var selectedNodeID: String? { document.selectedNodeID }
    var selectedEdgeID: String? { document.selectedEdgeID }
    var isEditing: Bool { document.isOpen }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
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
    /// The screen left while a tail was in flight. The host can compact the
    /// readable file meanwhile, so the next poll has to start from zero rather
    /// than append at an offset that now points at different bytes.
    private var transcriptNeedsReset = false

    func appeared() async {
        isVisible = true
        await load()
        syncWatching()
    }

    func disappeared() {
        isVisible = false
        stopPolling()
        transcriptNeedsReset = true
    }

    func pickerBackends(keeping id: String? = nil) -> [AgentBackend] {
        backends.visibleForPicker(keeping: id)
    }

    private var loadGeneration: UInt64 = 0

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            async let g = Bridge.workflows()
            async let r = Bridge.workflowRuns()
            async let b = Bridge.automationBackends()
            async let a = Bridge.automations()
            let (freshGraphs, freshRuns, freshBackends, freshJobs) = try await (g, r, b, a)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            graphs = freshGraphs
            runs = freshRuns
            #if os(macOS)
            RunNotifications.shared.settle(workflows: runs)
            #endif
            backends = freshBackends
            jobs = freshJobs
            hasLoaded = true
            errorMessage = nil
            if let id = working?.id, !id.isEmpty, !isDirty, let fresh = graphs.first(where: { $0.id == id }) {
                document.reloadClean(fresh)
            }
            syncWatching()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
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
        } else if selectedRun?.workflowID != id {
            clearForeignRunSelection()
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
        document.open(graph, dirty: graph.id.isEmpty)
        selectedGraphID = graph.id.isEmpty ? nil : graph.id
        selectedFocus = .graph
        // A run from another graph must not keep feeding the inspector its
        // steps and transcript after the canvas switched away.
        if selectedRun?.workflowID != graph.id {
            clearForeignRunSelection()
        }
        editorEpoch += 1
    }

    /// Drop a run that belongs to another graph, along with its tail.
    private func clearForeignRunSelection() {
        stopPolling()
        selectedRunID = nil
        selectedStepID = nil
        transcriptText = ""
        transcriptOffset = 0
    }

    func closeEditor() {
        document.endGroupedEdit()
        if document.isDirty, let working = document.graph {
            draft = working
        }
        document.close()
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

    var selectedNode: WorkflowNode? { document.selectedNode }

    func selectNode(_ id: String?) {
        document.selectNode(id)
        selectedFocus = .graph
        if let id {
            selectedStepID = id
            transcriptText = ""
            transcriptOffset = 0
            syncWatching()
        }
    }

    func selectEdge(_ id: String?) {
        document.selectEdge(id)
    }

    func mutate(_ body: (inout WorkflowGraph) -> Void) {
        document.mutate(body)
        syncDraft()
    }

    /// Write the working copy without a new undo. Pair with `beginGroupedEdit`.
    func writeWorking(_ body: (inout WorkflowGraph) -> Void) {
        document.writeWorking(body)
        syncDraft()
    }

    func beginGroupedEdit() {
        document.beginGroupedEdit()
    }

    func endGroupedEdit() {
        document.endGroupedEdit()
    }

    private func syncDraft() {
        guard let graph = document.graph else { return }
        if let draft, draft.id == graph.id {
            self.draft = graph
        }
    }

    func undo() {
        document.undo()
    }

    func redo() {
        document.redo()
    }

    func addNode(kind: WorkflowNodeKind, backend: String? = nil, automationID: String? = nil) {
        document.addNode(kind: kind, backend: backend, automationID: automationID)
        syncDraft()
    }

    func beginNodeMove() {
        document.beginNodeMove()
    }

    /// Live drag. Undo was captured at `beginNodeMove`.
    func moveNode(id: String, x: Double, y: Double) {
        document.moveNode(id: id, x: x, y: y)
    }

    func connect(from: String, to: String, when: WorkflowEdgeWhen) {
        document.connect(from: from, to: to, when: when)
        syncDraft()
    }

    func deleteSelection() {
        document.deleteSelection()
        syncDraft()
    }

    func updateNode(id: String, _ body: (inout WorkflowNode) -> Void) {
        document.updateNode(id: id, body)
        syncDraft()
    }

    func updateSelectedNode(_ body: (inout WorkflowNode) -> Void) {
        document.updateSelectedNode(body)
        syncDraft()
    }

    func updateSelectedEdge(when: WorkflowEdgeWhen) {
        document.updateSelectedEdge(when: when)
        syncDraft()
    }

    func renameWorking(_ name: String) {
        document.rename(name)
        syncDraft()
    }

    func setWorkingScope(_ scope: WorkflowScope, workspaceID: String?) {
        document.setScope(scope, workspaceID: workspaceID)
        syncDraft()
    }

    func setWorkingBudgetMinutes(_ minutes: UInt64) {
        document.setBudgetMinutes(minutes)
        syncDraft()
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
            document.close()
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
        document.replaceSteps(nodes: recipe.nodes, edges: recipe.edges, nameIfUntitled: recipe.name)
        syncDraft()
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
        if let issue = graph.stepsIssue {
            errorMessage = issue
            return
        }
        do {
            let saved: WorkflowGraph
            if graph.id.isEmpty {
                saved = try await Bridge.createWorkflow(graph)
            } else {
                do {
                    saved = try await Bridge.editWorkflow(graph, revision: graph.revision)
                } catch {
                    // A stale working copy must not overwrite the computer.
                    // Show the refusal and re-read what is actually saved.
                    errorMessage = error.localizedDescription
                    await load()
                    return
                }
            }
            draft = nil
            designTranscript = ""
            if document.isOpen {
                document.markSaved(saved)
            } else {
                document.open(saved, dirty: false)
            }
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
        if transcriptNeedsReset, isVisible {
            transcriptNeedsReset = false
            transcriptText = ""
            transcriptOffset = 0
        }
        guard let run = selectedRun, let stepID = selectedStepID else {
            stopPolling()
            return
        }
        guard run.workflowID == selectedGraphID else {
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
            if !isWatching(runID: runID, nodeID: nodeID) { return }
            if transcriptOffset <= before { return }
            if transcriptText.utf8.count >= transcriptDisplayCap { return }
        }
    }

    /// Whether the poll still belongs to the graph and step on screen.
    private func isWatching(runID: String, nodeID: String) -> Bool {
        guard selectedRunID == runID, selectedStepID == nodeID else { return false }
        return selectedRun?.workflowID == selectedGraphID
    }

    private func fetchTranscript(runID: String, nodeID: String, resetIfNeeded: Bool) async {
        if resetIfNeeded, !isWatching(runID: runID, nodeID: nodeID) {
            stopPolling()
            return
        }
        do {
            let chunk = try await Bridge.workflowTranscript(runID: runID, nodeID: nodeID, offset: transcriptOffset)
            if !isWatching(runID: runID, nodeID: nodeID) { return }
            if chunk.nextOffset < transcriptOffset {
                transcriptText = ""
                transcriptOffset = 0
                let again = try await Bridge.workflowTranscript(runID: runID, nodeID: nodeID, offset: 0)
                if !isWatching(runID: runID, nodeID: nodeID) { return }
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
