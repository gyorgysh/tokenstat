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
/// Everything lives in the daemon. The app lists graphs, shows a read-only
/// node outline, starts a run, and tails the selected step. The canvas that
/// edits the same IR lands next.
@MainActor
@Observable
final class WorkflowsModel {
    private(set) var graphs: [WorkflowGraph] = []
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
            graphs = try await g
            runs = try await r
            backends = try await b
            hasLoaded = true
            errorMessage = nil
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

    /// Live runs bound to this folder. The sidebar lists these.
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
        if let graph = graphs.first(where: { $0.id == id }), let last = lastRun(for: graph) {
            watch(last)
        }
    }

    func selectDraft() {
        selectedGraphID = draft?.id
        selectedFocus = .graph
        stopPolling()
    }

    func selectRun(_ run: WorkflowRunRecord) {
        selectedGraphID = run.workflowID
        selectedFocus = .run
        watch(run)
    }

    func selectStep(_ nodeID: String) {
        selectedStepID = nodeID
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func startBlank(scope: WorkflowScope = .global, workspaceID: String? = nil) {
        draft = WorkflowGraph.blank(scope: scope, workspaceID: workspaceID)
        designTranscript = ""
        selectDraft()
        noticeMessage = "Blank draft. Review it, then save. It will not run until you press Run."
    }

    func discardDraft() {
        draft = nil
        designTranscript = ""
        if selectedFocus == .graph, selectedGraphID == nil || !(graphs.contains { $0.id == selectedGraphID }) {
            selectedFocus = .none
            selectedGraphID = nil
        }
    }

    func design(prompt: String, workspaceID: String?, backend: String?) async {
        let intent = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else {
            errorMessage = "Describe the run first."
            return
        }
        isDesigning = true
        defer { isDesigning = false }
        do {
            let result = try await Bridge.designWorkflow(
                prompt: intent,
                workspaceID: workspaceID,
                backend: backend
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
        guard var graph = draft else { return }
        let name = graph.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "A workflow needs a name."
            return
        }
        graph.name = name
        do {
            let saved = try await Bridge.createWorkflow(graph)
            draft = nil
            designTranscript = ""
            errorMessage = nil
            showNotice("Saved \(saved.name).")
            await load()
            selectGraph(saved.id)
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
