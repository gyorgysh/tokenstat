// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct AutoCommitDraft: Codable, Equatable, Sendable {
    var backendID = ""
    var model = ""
    var pendingLaunch: AutomationRunSubmission?
    var retryableLaunch = false
}

struct AutoCommitRunRoute: Hashable, Identifiable, Sendable {
    var jobID: String
    var runID: String?
    var id: String { jobID + "|" + (runID ?? "") }
}

protocol AutoCommitService: Sendable {
    func jobs() async throws -> [Automation]
    func runs() async throws -> [RunRecord]
    func backends() async throws -> [AgentBackend]
    func supportsReceipts() async -> Bool
    func create(_ job: Automation) async throws -> Automation
    func update(_ job: Automation) async throws -> Automation
    func edit(_ job: Automation, revision: UInt64) async throws -> Automation
    func run(_ id: String) async throws -> Automation
    func runOnce(id: String, operationID: String) async throws -> AutomationRunOutcome
    func runReceipt(operationID: String) async throws -> AutomationRunOutcome?
}

/// Starts the folder's Auto commit job. Invoking this is the run, not a
/// settings sheet. Create stays on the legacy host path because Auto commit
/// is one job per folder, not a new scheduled job.
@MainActor
@Observable
final class AutoCommitSession {
    let peer: String
    let workspaceID: String
    let folderName: String
    let hostName: String
    private let service: any AutoCommitService

    var draft = AutoCommitDraft()
    private(set) var backends: [AgentBackend] = []
    private(set) var job: Automation?
    private(set) var lastRun: RunRecord?
    private(set) var loaded = false
    private(set) var working = false
    private(set) var supportsReceipts = false
    var errorMessage: String?
    private(set) var limitation: String?

    static let legacyLimitation =
        "This computer cannot confirm a lost start. Open Automations if the run is already going."

    @ObservationIgnored private let storage: WorkbenchDraftFile<AutoCommitDraft>?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var saved = AutoCommitDraft()
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        peer: String,
        workspaceID: String,
        folderName: String,
        hostName: String,
        scope: WorkReference.Scope?,
        hostIdentity: String?,
        service: any AutoCommitService,
        draftDirectory: URL? = nil
    ) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.folderName = folderName
        self.hostName = hostName
        self.service = service
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: workspaceID)
                + "auto-commit"
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory, maximumBytes: 16 * 1024)
        } else if let draftDirectory {
            storage = WorkbenchDraftFile(
                key: "auto-commit|\(peer)|\(workspaceID)",
                directory: draftDirectory,
                maximumBytes: 16 * 1024
            )
        } else {
            storage = nil
        }
    }

    var selectedBackend: AgentBackend? {
        backends.first { $0.id == draft.backendID } ?? backends.first
    }

    var isRunning: Bool { lastRun?.isRunning == true }

    var hasPendingLaunch: Bool { draft.pendingLaunch != nil && !isRunning }

    var canRetryLaunch: Bool { hasPendingLaunch && draft.retryableLaunch }

    var canStart: Bool {
        loaded && !working && selectedBackend != nil && !(selectedBackend?.models.isEmpty ?? true)
            && selectedBackend?.id != "sh" && !isRunning && !hasPendingLaunch
    }

    var route: AutoCommitRunRoute? {
        guard let job else { return nil }
        return AutoCommitRunRoute(jobID: job.id, runID: lastRun?.id ?? job.lastRunID)
    }

    func load() async {
        if storage != nil, !loaded {
            do {
                if let record = try await storage?.load() {
                    draft = record.value
                    revision = record.revision
                    saved = record.value
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh()
        loaded = true
        reconcilePickers()
        if draft != saved { _ = await persist() }
        await confirmPendingLaunch()
    }

    func setBackend(_ id: String) {
        guard id != draft.backendID else { return }
        draft.backendID = id
        draft.model = AutoCommitJob.preferredModel(in: selectedBackend, stored: "")
        Task { _ = await persist() }
    }

    func setModel(_ value: String) {
        guard value != draft.model else { return }
        draft.model = value
        Task { _ = await persist() }
    }

    func start() async {
        guard canStart, let backend = selectedBackend else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        guard await persist() else { return }
        let prepared = AutoCommitJob.job(
            in: workspaceID,
            workspaceName: folderName,
            backend: backend.id,
            model: draft.model.isEmpty ? nil : draft.model,
            existing: job
        )
        let savedJob: Automation
        if job != nil {
            do {
                savedJob = try await saveExisting(prepared)
            } catch {
                errorMessage = display(error)
                await refresh()
                return
            }
        } else {
            do {
                savedJob = try await service.create(prepared)
            } catch {
                await refresh()
                if let existing = job, !isRunning {
                    await launch(existing)
                    return
                }
                if isRunning { return }
                errorMessage = display(error)
                return
            }
        }
        job = savedJob
        await launch(savedJob)
    }

    func checkLaunch() async {
        guard !working, let pending = draft.pendingLaunch else { return }
        working = true
        defer { working = false }
        do {
            if let outcome = try await service.runReceipt(operationID: pending.operationID) {
                adopt(outcome)
                _ = await persist()
                await refresh()
            } else {
                draft.retryableLaunch = true
                errorMessage = nil
                _ = await persist()
            }
        } catch {
            errorMessage = display(error)
        }
    }

    func retryLaunch() async {
        guard canRetryLaunch, let pending = draft.pendingLaunch else { return }
        working = true
        defer { working = false }
        draft.retryableLaunch = false
        guard await persist() else { return }
        await submitLaunch(pending)
    }

    func seedPendingLaunch(_ submission: AutomationRunSubmission, retryable: Bool) async {
        draft.pendingLaunch = submission
        draft.retryableLaunch = retryable
        _ = await persist()
    }

    private func saveExisting(_ job: Automation) async throws -> Automation {
        if supportsReceipts {
            return try await service.edit(job, revision: job.revision)
        }
        return try await service.update(job)
    }

    private func launch(_ job: Automation) async {
        if supportsReceipts {
            let pending = draft.pendingLaunch
                ?? AutomationRunSubmission(
                    operationID: "automation-run-\(UUID().uuidString)",
                    jobID: job.id
                )
            draft.pendingLaunch = pending
            draft.retryableLaunch = false
            guard await persist() else { return }
            await submitLaunch(pending)
            return
        }
        do {
            let updated = try await service.run(job.id)
            self.job = updated
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = display(error)
            if !supportsReceipts {
                limitation = Self.legacyLimitation
            }
        }
    }

    private func submitLaunch(_ pending: AutomationRunSubmission) async {
        do {
            let outcome = try await service.runOnce(id: pending.jobID, operationID: pending.operationID)
            adopt(outcome)
            _ = await persist()
            await refresh()
        } catch {
            if let outcome = try? await service.runReceipt(operationID: pending.operationID) {
                adopt(outcome)
                _ = await persist()
                await refresh()
                return
            }
            draft.retryableLaunch = true
            errorMessage = display(error)
            _ = await persist()
        }
    }

    private func confirmPendingLaunch() async {
        guard supportsReceipts, let pending = draft.pendingLaunch else { return }
        if let outcome = try? await service.runReceipt(operationID: pending.operationID) {
            adopt(outcome)
            _ = await persist()
            await refresh()
        }
    }

    private func adopt(_ outcome: AutomationRunOutcome) {
        draft.pendingLaunch = nil
        draft.retryableLaunch = false
        if let updated = outcome.job {
            job = updated
        } else if !outcome.jobID.isEmpty {
            var current = job ?? AutoCommitJob.job(
                in: workspaceID,
                workspaceName: folderName,
                backend: draft.backendID,
                model: draft.model.isEmpty ? nil : draft.model
            )
            current.id = outcome.jobID
            if !outcome.runID.isEmpty { current.lastRunID = outcome.runID }
            job = current
        }
        if let run = outcome.run {
            lastRun = run
        }
        errorMessage = nil
        limitation = nil
    }

    private func refresh() async {
        do {
            async let jobs = service.jobs()
            async let runs = service.runs()
            async let listed = service.backends()
            let receipts = await service.supportsReceipts()
            let (freshJobs, freshRuns, freshBackends) = try await (jobs, runs, listed)
            supportsReceipts = receipts
            backends = AutoCommitJob.commitBackends(
                freshBackends.visibleForPicker(keeping: draft.backendID),
                keeping: draft.backendID
            )
            job = AutoCommitJob.match(in: freshJobs, workspaceID: workspaceID)
            if let job {
                lastRun = freshRuns.first { $0.id == job.lastRunID }
                    ?? freshRuns.filter { $0.jobId == job.id }.max(by: { $0.startedAtMs < $1.startedAtMs })
                if lastRun?.isRunning == true {
                    draft.pendingLaunch = nil
                    draft.retryableLaunch = false
                }
            } else {
                lastRun = nil
            }
            if supportsReceipts {
                limitation = nil
            } else {
                limitation = Self.legacyLimitation
            }
        } catch {
            errorMessage = display(error)
        }
    }

    private func reconcilePickers() {
        if let backend = selectedBackend {
            if draft.backendID != backend.id { draft.backendID = backend.id }
            let model = AutoCommitJob.preferredModel(in: backend, stored: draft.model)
            if draft.model != model { draft.model = model }
        } else if let first = backends.first {
            draft.backendID = first.id
            draft.model = AutoCommitJob.preferredModel(in: first, stored: draft.model)
        }
    }

    @discardableResult
    func persist() async -> Bool {
        guard let storage else { return true }
        while writing { await withCheckedContinuation { writeWaiters.append($0) } }
        writing = true
        defer {
            writing = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            let record = try await storage.save(draft, expectedRevision: revision)
            revision = record.revision
            saved = record.value
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func display(_ error: Error) -> String {
        #if !os(macOS)
        ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        #else
        error.localizedDescription
        #endif
    }
}
