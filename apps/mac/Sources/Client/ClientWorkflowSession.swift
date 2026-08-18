// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import Foundation
import Observation

/// Graphs and runs for one folder on a peer, plus the writes a phone or
/// iPad is allowed to make.
///
/// Construction stays on the Mac. This object lists, runs, stops, continues
/// a gate, flips a schedule, and tails a step. The views decide how that
/// looks. They do not talk to the host themselves.
@MainActor
@Observable
final class ClientWorkflowSession {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    private(set) var graphs: [WorkflowGraph] = []
    private(set) var runs: [WorkflowRunRecord] = []
    private(set) var loaded = false
    var errorMessage: String?
    var input = ""
    var working = false

    var selectedGraphID: String?
    var selectedRunID: String?
    var selectedNodeID: String?

    private(set) var transcriptText = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var pollingKey: String?
    private var isVisible = false
    private var visibility = 0

    init(peer: String, workspaceID: String, hostName: String, folderName: String, graphID: String? = nil) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        self.selectedGraphID = graphID
    }

    var selectedGraph: WorkflowGraph? {
        guard let selectedGraphID else { return graphs.first }
        return graphs.first { $0.id == selectedGraphID } ?? graphs.first
    }

    var selectedRun: WorkflowRunRecord? {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return liveRun ?? lastRun(for: selectedGraph)
    }

    var liveRun: WorkflowRunRecord? {
        guard let id = selectedGraph?.id else { return nil }
        return runs.first { $0.workflowID == id && $0.isLive }
    }

    func lastRun(for graph: WorkflowGraph?) -> WorkflowRunRecord? {
        guard let graph else { return nil }
        if let id = graph.lastRunID, let run = runs.first(where: { $0.id == id }) {
            return run
        }
        return runs.first { $0.workflowID == graph.id }
    }

    func runs(of graph: WorkflowGraph) -> [WorkflowRunRecord] {
        runs.filter { $0.workflowID == graph.id }
    }

    func appeared() async {
        visibility += 1
        isVisible = visibility > 0
        await load()
        syncWatching()
    }

    func disappeared() {
        visibility = max(0, visibility - 1)
        isVisible = visibility > 0
        if isVisible {
            syncWatching()
        } else {
            stopPolling()
        }
    }

    func load() async {
        do {
            async let all = ClientRemote.workflows(peer: peer)
            async let history = ClientRemote.workflowRuns(peer: peer)
            graphs = try await all.filter { $0.workspaceID == workspaceID }
            runs = try await history.filter { $0.workspaceID == workspaceID }
            errorMessage = nil
            if selectedGraphID == nil {
                selectedGraphID = graphs.first?.id
            }
            if selectedRunID == nil, let graph = selectedGraph {
                selectedRunID = lastRun(for: graph)?.id
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
        syncWatching()
    }

    func selectGraph(_ id: String) {
        selectedGraphID = id
        selectedNodeID = nil
        selectedRunID = lastRun(for: graphs.first { $0.id == id })?.id
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func selectRun(_ run: WorkflowRunRecord) {
        selectedRunID = run.id
        selectedGraphID = run.workflowID
        selectedNodeID = run.currentNodeID ?? run.steps.last?.nodeID
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func selectNode(_ id: String) {
        selectedNodeID = id
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func run() async {
        guard !working, let graph = selectedGraph else { return }
        working = true
        defer { working = false }
        do {
            let run = try await ClientRemote.runWorkflow(
                peer: peer,
                id: graph.id,
                input: input,
                workspaceID: workspaceID
            )
            errorMessage = nil
            await load()
            selectRun(run)
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func stop() async {
        guard !working, let run = liveRun ?? selectedRun, run.isLive else { return }
        working = true
        defer { working = false }
        do {
            try await ClientRemote.killWorkflow(peer: peer, runID: run.id)
            errorMessage = nil
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func continueGate() async {
        guard !working, let run = liveRun ?? selectedRun, run.isWaiting else { return }
        working = true
        defer { working = false }
        do {
            let next = try await ClientRemote.continueWorkflow(peer: peer, runID: run.id)
            errorMessage = nil
            await load()
            selectRun(next)
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func toggleSchedule() async {
        guard !working else { return }
        working = true
        defer { working = false }
        // The host replaces the whole graph. Re-read first so a stale
        // phone copy cannot wipe a Mac edit.
        await load()
        guard var graph = selectedGraph, graph.schedule.repeats else { return }
        graph.enabled.toggle()
        do {
            let updated = try await ClientRemote.updateWorkflow(peer: peer, graph: graph)
            errorMessage = nil
            if let index = graphs.firstIndex(where: { $0.id == updated.id }) {
                graphs[index] = updated
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func syncWatching() {
        guard isVisible, let run = selectedRun, let node = transcriptNode(in: run) else {
            stopPolling()
            return
        }
        let key = "\(run.id):\(node)"
        if run.isLive {
            startPolling(runID: run.id, nodeID: node, key: key)
        } else {
            stopPolling()
            Task { await fetchUntilCaughtUp(runID: run.id, nodeID: node) }
        }
    }

    private func transcriptNode(in run: WorkflowRunRecord) -> String? {
        if let selectedNodeID, run.steps.contains(where: { $0.nodeID == selectedNodeID })
            || (selectedGraph?.nodes.contains(where: { $0.id == selectedNodeID }) ?? false)
        {
            return selectedNodeID
        }
        return run.currentNodeID ?? run.steps.last?.nodeID
    }

    private func startPolling(runID: String, nodeID: String, key: String) {
        if pollTask != nil, pollingKey == key { return }
        stopPolling()
        pollingKey = key
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchTranscript(runID: runID, nodeID: nodeID)
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
            let latest = try await ClientRemote.workflowRuns(peer: peer)
            runs = latest.filter { $0.workspaceID == workspaceID }
            if let run = selectedRun, !run.isLive {
                stopPolling()
                if let node = transcriptNode(in: run) {
                    await fetchUntilCaughtUp(runID: run.id, nodeID: node)
                }
            }
        } catch {
            // The next tick tries again.
        }
    }

    private func fetchUntilCaughtUp(runID: String, nodeID: String) async {
        var slices = 0
        while slices < 8 {
            slices += 1
            let before = transcriptOffset
            await fetchTranscript(runID: runID, nodeID: nodeID)
            if transcriptOffset <= before { return }
        }
    }

    private func fetchTranscript(runID: String, nodeID: String) async {
        do {
            let chunk = try await ClientRemote.workflowTranscript(
                peer: peer,
                runID: runID,
                nodeID: nodeID,
                offset: transcriptOffset
            )
            if chunk.nextOffset < transcriptOffset {
                transcriptText = ""
                transcriptOffset = 0
                let again = try await ClientRemote.workflowTranscript(
                    peer: peer,
                    runID: runID,
                    nodeID: nodeID,
                    offset: 0
                )
                transcriptText = ClientTranscript.capped(again.text)
                transcriptOffset = again.nextOffset
                return
            }
            if !chunk.text.isEmpty {
                transcriptText = ClientTranscript.capped(transcriptText + chunk.text)
            }
            transcriptOffset = chunk.nextOffset
        } catch {
            // A just-finished step may still be writing. The next tick retries.
        }
    }
}

#endif
