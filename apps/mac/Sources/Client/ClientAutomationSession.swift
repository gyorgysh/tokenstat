// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import Foundation
import Observation

/// Jobs and runs for one folder on a peer. Run, pause, stop, tail.
///
/// Creating and editing a job stay on the Mac. This is the control surface.
@MainActor
@Observable
final class ClientAutomationSession {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    private(set) var jobs: [Automation] = []
    private(set) var runs: [RunRecord] = []
    private(set) var loaded = false
    var errorMessage: String?
    var working = false

    var selectedJobID: String?
    var selectedRunID: String?

    private(set) var transcriptText = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var pollingID: String?
    private var isVisible = false
    private var visibility = 0

    init(peer: String, workspaceID: String, hostName: String, folderName: String, jobID: String? = nil) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        self.selectedJobID = jobID
    }

    var selectedJob: Automation? {
        guard let selectedJobID else { return jobs.first }
        return jobs.first { $0.id == selectedJobID } ?? jobs.first
    }

    var selectedRun: RunRecord? {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return liveRun ?? lastRun(for: selectedJob)
    }

    var liveRun: RunRecord? {
        guard let id = selectedJob?.id else { return nil }
        return runs.first { $0.jobId == id && $0.isRunning }
    }

    func lastRun(for job: Automation?) -> RunRecord? {
        guard let job else { return nil }
        if let id = job.lastRunID, let run = runs.first(where: { $0.id == id }) {
            return run
        }
        return runs.first { $0.jobId == job.id }
    }

    func runs(of job: Automation) -> [RunRecord] {
        runs.filter { $0.jobId == job.id }
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
            async let all = ClientRemote.automations(peer: peer)
            async let history = ClientRemote.automationRuns(peer: peer)
            jobs = try await all.filter { $0.workspaceID == workspaceID }
            runs = try await history.filter { $0.workspaceID == workspaceID }
            errorMessage = nil
            if selectedJobID == nil {
                selectedJobID = jobs.first?.id
            }
            if selectedRunID == nil, let job = selectedJob {
                selectedRunID = lastRun(for: job)?.id
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
        syncWatching()
    }

    func selectJob(_ id: String) {
        selectedJobID = id
        selectedRunID = lastRun(for: jobs.first { $0.id == id })?.id
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func selectRun(_ run: RunRecord) {
        selectedRunID = run.id
        selectedJobID = run.jobId
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func run() async {
        guard !working, let job = selectedJob else { return }
        working = true
        defer { working = false }
        do {
            let updated = try await ClientRemote.runAutomation(peer: peer, id: job.id)
            errorMessage = nil
            await load()
            if let id = updated.lastRunID, let run = runs.first(where: { $0.id == id }) {
                selectRun(run)
            } else if let last = lastRun(for: updated) ?? lastRun(for: job) {
                selectRun(last)
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func stop() async {
        guard !working, let run = liveRun ?? selectedRun, run.isRunning else { return }
        working = true
        defer { working = false }
        do {
            try await ClientRemote.killAutomation(peer: peer, runID: run.id)
            errorMessage = nil
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func toggleSchedule() async {
        guard !working, let job = selectedJob else { return }
        working = true
        defer { working = false }
        do {
            let updated = try await ClientRemote.setAutomation(
                peer: peer,
                id: job.id,
                enabled: !job.enabled
            )
            errorMessage = nil
            if let index = jobs.firstIndex(where: { $0.id == updated.id }) {
                jobs[index] = updated
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func syncWatching() {
        guard isVisible, let run = selectedRun else {
            stopPolling()
            return
        }
        if run.isRunning {
            startPolling(run.id)
        } else {
            stopPolling()
            Task { await fetchUntilCaughtUp(id: run.id) }
        }
    }

    private func startPolling(_ id: String) {
        if pollTask != nil, pollingID == id { return }
        stopPolling()
        pollingID = id
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchTranscript(id: id)
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
        pollingID = nil
    }

    private func refreshRuns() async {
        do {
            let latest = try await ClientRemote.automationRuns(peer: peer)
            runs = latest.filter { $0.workspaceID == workspaceID }
            if let run = selectedRun, !run.isRunning {
                stopPolling()
                await fetchUntilCaughtUp(id: run.id)
            }
        } catch {
            // The next tick tries again.
        }
    }

    private func fetchUntilCaughtUp(id: String) async {
        var slices = 0
        while slices < 8 {
            slices += 1
            let before = transcriptOffset
            await fetchTranscript(id: id)
            if transcriptOffset <= before { return }
        }
    }

    private func fetchTranscript(id: String) async {
        do {
            let chunk = try await ClientRemote.automationTranscript(
                peer: peer,
                id: id,
                offset: transcriptOffset
            )
            if chunk.nextOffset < transcriptOffset {
                transcriptText = ""
                transcriptOffset = 0
                let again = try await ClientRemote.automationTranscript(
                    peer: peer,
                    id: id,
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
            // A just-finished run may still have its file in flight.
        }
    }
}

#endif
