// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import Foundation
import Observation

/// Jobs and runs for one folder on a peer. Create, edit, delete, run, pause, stop, tail.
@MainActor
@Observable
final class ClientAutomationSession {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String
    private let service: any ClientJobService

    private(set) var jobs: [Automation] = []
    private(set) var runs: [RunRecord] = []
    private(set) var loaded = false
    /// IANA name of the connected computer's scheduler. Empty until queue
    /// answers, and never this device's zone.
    private(set) var schedulerTimezone: String = ""
    /// Host-wide queue, not this folder. Nil until `automation.queue` answers.
    private(set) var queue: AutomationQueue?
    var errorMessage: String?
    var working = false

    var selectedJobID: String?
    var selectedRunID: String?

    private(set) var transcriptText = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var pollingID: String?
    private var loadGeneration = 0
    private var isVisible = false
    private var visibility = 0
    /// Set when this session is a detail page for one job. A missing id
    /// then stays missing instead of becoming some other job.
    private let pinnedJobID: String?
    private let pinnedRunID: String?

    init(peer: String, workspaceID: String, hostName: String, folderName: String, jobID: String? = nil, runID: String? = nil, service: any ClientJobService = ClientRemoteJobService()) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        self.service = service
        self.pinnedJobID = jobID
        self.pinnedRunID = runID
        self.selectedJobID = jobID
        self.selectedRunID = runID
    }

    /// When the caller asked for a specific job, do not fall back to another
    /// one. The detail screen has to show empty, not a neighbour.
    var selectedJob: Automation? {
        if let selectedJobID {
            return jobs.first { $0.id == selectedJobID }
        }
        if pinnedRunID != nil { return nil }
        return jobs.first
    }

    var selectedRun: RunRecord? {
        if let selectedRunID {
            return runs.first { $0.id == selectedRunID }
        }
        return liveRun ?? lastRun(for: selectedJob)
    }

    var liveRun: RunRecord? {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID && $0.isRunning }) {
            return run
        }
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
        loadGeneration += 1
        let generation = loadGeneration
        do {
            async let all = service.automations(peer: peer)
            async let history = service.automationRuns(peer: peer)
            async let hostQueue = service.automationQueue(peer: peer)
            let (freshItems, freshRuns) = try await (all, history)
            let freshQueue = try? await hostQueue
            guard generation == loadGeneration, !Task.isCancelled else { return }
            jobs = freshItems.filter { $0.workspaceID == workspaceID }
            runs = freshRuns.filter { $0.workspaceID == workspaceID }
            if let freshQueue {
                queue = freshQueue
                if let timezone = HostScheduleClock.resolved(freshQueue.timezone) {
                    schedulerTimezone = timezone
                }
            }
            errorMessage = nil
            if selectedJobID == nil, pinnedRunID == nil {
                selectedJobID = pinnedJobID ?? jobs.first?.id
            }
            if selectedRunID == nil, let job = selectedJob {
                selectedRunID = lastRun(for: job)?.id
            } else if selectedRunID == nil {
                selectedRunID = pinnedRunID
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
        syncWatching()
    }

    func queueService() -> ClientJobQueueService {
        ClientJobQueueService(peer: peer, jobs: service)
    }

    func selectJob(_ id: String) {
        guard jobs.contains(where: { $0.id == id }), selectedJobID != id else { return }
        selectedJobID = id
        selectedRunID = lastRun(for: jobs.first { $0.id == id })?.id
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func selectRun(_ run: RunRecord) {
        guard run.workspaceID == workspaceID else { return }
        guard selectedRunID != run.id else { return }
        selectedRunID = run.id
        if jobs.contains(where: { $0.id == run.jobId }) { selectedJobID = run.jobId }
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    func run() async {
        guard !working, let job = selectedJob else { return }
        working = true
        defer { working = false }
        do {
            let updated = try await service.runAutomation(peer: peer, id: job.id)
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
            try await service.killAutomation(peer: peer, runID: run.id)
            errorMessage = nil
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func remove(_ job: Automation) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await service.removeAutomation(peer: peer, id: job.id)
            errorMessage = nil
            if selectedJobID == job.id {
                selectedJobID = nil
                selectedRunID = nil
            }
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
            let updated = try await service.setAutomation(
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
            startCatchUp(id: run.id)
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

    private func startCatchUp(id: String) {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            await self?.fetchUntilCaughtUp(id: id)
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollingID = nil
        catchUpTask?.cancel()
        catchUpTask = nil
    }

    private func refreshRuns() async {
        do {
            let latest = try await service.automationRuns(peer: peer)
            runs = latest.filter { $0.workspaceID == workspaceID }
            if let run = selectedRun, !run.isRunning {
                stopPolling()
                startCatchUp(id: run.id)
            }
        } catch {
            // The next tick tries again.
        }
    }

    private func stillWatching(_ id: String) -> Bool {
        selectedRunID == id
    }

    private func fetchUntilCaughtUp(id: String) async {
        var slices = 0
        while slices < 8 {
            guard !Task.isCancelled else { return }
            slices += 1
            let before = transcriptOffset
            await fetchTranscript(id: id)
            if Task.isCancelled || !stillWatching(id) { return }
            if transcriptOffset <= before { return }
        }
    }

    private func fetchTranscript(id: String) async {
        do {
            let chunk = try await service.automationTranscript(
                peer: peer,
                id: id,
                offset: transcriptOffset
            )
            if Task.isCancelled || !stillWatching(id) { return }
            if chunk.nextOffset < transcriptOffset {
                transcriptText = ""
                transcriptOffset = 0
                let again = try await service.automationTranscript(
                    peer: peer,
                    id: id,
                    offset: 0
                )
                if Task.isCancelled || !stillWatching(id) { return }
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
