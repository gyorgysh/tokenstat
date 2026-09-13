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
    private(set) var supportsReceipts = false
    private(set) var pendingLaunches: [String: AutomationRunSubmission] = [:]
    private(set) var retryableLaunchIDs: Set<String> = []

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
    private let launchStorage: WorkbenchDraftFile<SavedAutomationLaunches>?
    private var launchRevision: String?
    private var writingLaunches = false

    init(
        peer: String,
        workspaceID: String,
        hostName: String,
        folderName: String,
        jobID: String? = nil,
        runID: String? = nil,
        service: any ClientJobService = ClientRemoteJobService(),
        launchDirectory: URL? = nil
    ) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        self.service = service
        self.pinnedJobID = jobID
        self.pinnedRunID = runID
        self.selectedJobID = jobID
        self.selectedRunID = runID
        if let scope = WorkSessionContext.shared.scope, !peer.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: peer, workspaceID: workspaceID) + "automation-launches"
            launchStorage = WorkbenchDraftFile(key: key, directory: launchDirectory, maximumBytes: 64 * 1024)
        } else if let launchDirectory {
            launchStorage = WorkbenchDraftFile(
                key: "automation-launches|\(peer)|\(workspaceID)",
                directory: launchDirectory,
                maximumBytes: 64 * 1024
            )
        } else {
            launchStorage = nil
        }
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
        guard let latest = lastRun(for: selectedJob), latest.isRunning else { return nil }
        return latest
    }

    func lastRun(for job: Automation?) -> RunRecord? {
        guard let job else { return nil }
        let jobRuns = runs.filter { $0.jobId == job.id }
        if let latest = AutomationRunHistory.latest(
            jobRuns, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        ) {
            return latest
        }
        if let id = job.lastRunID {
            return runs.first { $0.id == id }
        }
        return nil
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

    func pendingLaunch(for job: Automation) -> AutomationRunSubmission? {
        pendingLaunches[job.id]
    }

    func canRetryLaunch(for job: Automation) -> Bool {
        retryableLaunchIDs.contains(job.id)
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        supportsReceipts = await service.supportsAutomationReceipts(peer: peer)
        await restoreLaunches()
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
            await reconcilePendingLaunches()
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
        if supportsReceipts {
            let submission = pendingLaunches[job.id] ?? AutomationRunSubmission(
                operationID: "automation-run-\(UUID().uuidString)",
                jobID: job.id
            )
            pendingLaunches[job.id] = submission
            retryableLaunchIDs.remove(job.id)
            guard await persistLaunches() else { return }
            await submitLaunch(submission)
            return
        }
        working = true
        defer { working = false }
        do {
            let updated = try await service.runAutomation(peer: peer, id: job.id)
            errorMessage = nil
            await adoptRun(of: updated, fallback: job)
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func checkLaunch() async {
        guard !working, let job = selectedJob, let submission = pendingLaunches[job.id] else { return }
        working = true
        defer { working = false }
        do {
            if let outcome = try await service.automationRunReceipt(peer: peer, operationID: submission.operationID) {
                await confirmLaunch(outcome, submission: submission)
            } else {
                retryableLaunchIDs.insert(job.id)
                errorMessage = nil
            }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    func retryLaunch() async {
        guard !working, let job = selectedJob, let submission = pendingLaunches[job.id], retryableLaunchIDs.contains(job.id) else { return }
        retryableLaunchIDs.remove(job.id)
        guard await persistLaunches() else { return }
        await submitLaunch(submission)
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

    private struct SavedAutomationLaunches: Codable, Equatable, Sendable {
        var pending: [String: AutomationRunSubmission] = [:]
    }

    private func restoreLaunches() async {
        guard let launchStorage, pendingLaunches.isEmpty else { return }
        if let record = try? await launchStorage.load() {
            launchRevision = record.revision
            pendingLaunches = record.value.pending
        }
    }

    @discardableResult
    private func persistLaunches() async -> Bool {
        guard let launchStorage, !writingLaunches else {
            return launchStorage == nil
        }
        writingLaunches = true
        defer { writingLaunches = false }
        do {
            let record = try await launchStorage.save(
                SavedAutomationLaunches(pending: pendingLaunches),
                expectedRevision: launchRevision
            )
            launchRevision = record.revision
            return true
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return false
        }
    }

    private func submitLaunch(_ submission: AutomationRunSubmission) async {
        working = true
        defer { working = false }
        do {
            let outcome = try await service.runAutomationOnce(
                peer: peer,
                id: submission.jobID,
                operationID: submission.operationID
            )
            await confirmLaunch(outcome, submission: submission)
        } catch {
            if let outcome = try? await service.automationRunReceipt(peer: peer, operationID: submission.operationID) {
                await confirmLaunch(outcome, submission: submission)
                return
            }
            retryableLaunchIDs.insert(submission.jobID)
            errorMessage = ClientTunnelCopy.display(
                "The computer did not confirm this run. Check it before starting another. \(error.localizedDescription)",
                host: hostName
            )
        }
    }

    private func confirmLaunch(_ outcome: AutomationRunOutcome, submission: AutomationRunSubmission) async {
        guard outcome.operationID == submission.operationID else {
            errorMessage = ClientTunnelCopy.display("The computer returned a different run. Check this job again.", host: hostName)
            return
        }
        pendingLaunches[submission.jobID] = nil
        retryableLaunchIDs.remove(submission.jobID)
        errorMessage = nil
        _ = await persistLaunches()
        await load()
        if let run = outcome.run, runs.contains(where: { $0.id == run.id }) {
            selectRun(run)
        } else if !outcome.runID.isEmpty, let run = runs.first(where: { $0.id == outcome.runID }) {
            selectRun(run)
        } else if let job = outcome.job {
            await adoptRun(of: job, fallback: job)
        }
    }

    private func adoptRun(of updated: Automation, fallback: Automation) async {
        await load()
        if let id = updated.lastRunID, let run = runs.first(where: { $0.id == id }) {
            selectRun(run)
        } else if let last = lastRun(for: updated) ?? lastRun(for: fallback) {
            selectRun(last)
        }
    }

    private func reconcilePendingLaunches() async {
        guard supportsReceipts, !pendingLaunches.isEmpty else { return }
        var changed = false
        for (jobID, submission) in pendingLaunches {
            if let outcome = try? await service.automationRunReceipt(peer: peer, operationID: submission.operationID) {
                pendingLaunches[jobID] = nil
                retryableLaunchIDs.remove(jobID)
                changed = true
                if let run = outcome.run ?? runs.first(where: { $0.id == outcome.runID }) {
                    selectRun(run)
                }
            }
        }
        if changed { _ = await persistLaunches() }
    }

    func seedPendingLaunch(_ submission: AutomationRunSubmission, retryable: Bool) async {
        pendingLaunches[submission.jobID] = submission
        if retryable {
            retryableLaunchIDs.insert(submission.jobID)
        } else {
            retryableLaunchIDs.remove(submission.jobID)
        }
        _ = await persistLaunches()
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
