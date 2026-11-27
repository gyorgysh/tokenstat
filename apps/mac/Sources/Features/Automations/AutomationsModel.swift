// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

import Foundation
import Observation

/// How much readable transcript the inspector keeps. The host already caps
/// each reply and the on-disk readable file. This is the last line of defence
/// so a live tail cannot grow a SwiftUI `Text` without bound.
private let transcriptDisplayCap = 256 * 1024

enum AutomationFocus: Sendable {
    case none
    case job
    case run
}

@MainActor
@Observable
final class AutomationsModel {
    private(set) var jobs: [Automation] = []
    var scope: String?
    private(set) var runs: [RunRecord] = []
    private(set) var backends: [AgentBackend] = []

    private(set) var hasLoaded = false

    var errorMessage: String?
    var noticeMessage: String?
    private var pendingCreate: (operationID: String, job: Automation)?
    private var pendingLaunches: [String: String] = [:]

    var queueBudgetMinutes = "180"
    var queueNoLimit = false
    var queueMaxConcurrent = "2"
    private var savedQueueBudgetSeconds: UInt64 = 10_800
    private(set) var savedQueueBudgetMinutes = "180"
    private(set) var savedQueueNoLimit = false
    private(set) var savedQueueMaxConcurrent = "2"
    private(set) var schedulerTimezone: String = TimeZone.current.identifier

    var queueDirty: Bool {
        queueBudgetMinutes != savedQueueBudgetMinutes
            || queueNoLimit != savedQueueNoLimit
            || queueMaxConcurrent != savedQueueMaxConcurrent
    }

    private(set) var watchingRunID: String?
    private(set) var selectedRunID: String?
    private(set) var selectedJobID: String?
    private(set) var selectedFocus: AutomationFocus = .none
    private(set) var transcriptText: String = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var pollingID: String?
    private var transcriptNeedsReset = false
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
        transcriptNeedsReset = true
    }

    func pickerBackends(keeping id: String? = nil) -> [AgentBackend] {
        backends.visibleForPicker(keeping: id)
    }

    func defaultBackend(keeping id: String? = nil) -> AgentBackend? {
        backends.defaultForPicker(keeping: id)
    }

    private var loadGeneration: UInt64 = 0

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            async let j = Bridge.automations()
            async let r = Bridge.automationRuns()
            async let b = Bridge.automationBackends()
            async let q = Bridge.automationQueue()
            let (freshJobs, freshRuns, freshBackends) = try await (j, r, b)
            let freshQueue = try? await q
            guard !Task.isCancelled, generation == loadGeneration else { return }
            jobs = freshJobs
            runs = freshRuns
            #if os(macOS)
            RunNotifications.shared.settle(automations: runs)
            #endif
            backends = freshBackends
            if let queue = freshQueue, !queueDirty {
                applyQueue(queue)
            }
            hasLoaded = true
            errorMessage = nil
            syncWatching()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    var liveRun: RunRecord? {
        runs.first(where: \.isRunning) ?? runs.first
    }

    static var autoCommitName: String { AutoCommitJob.name }

    func autoCommitJobs(in workspaceID: String) -> [Automation] {
        jobs.filter {
            $0.workspaceID == workspaceID && AutoCommitJob.isName($0.name)
        }
    }

    func autoCommitJob(in workspaceID: String) -> Automation? {
        let matches = autoCommitJobs(in: workspaceID)
        if let live = matches.first(where: { lastRun(for: $0)?.isRunning == true }) {
            return live
        }
        return matches.first { lastRun(for: $0) != nil } ?? matches.first
    }

    static func isAutoCommitName(_ name: String) -> Bool {
        AutoCommitJob.isName(name)
    }

    func isAutoCommitRunning(in workspaceID: String) -> Bool {
        autoCommitJobs(in: workspaceID).contains { lastRun(for: $0)?.isRunning == true }
    }

    var scoped: [Automation] {
        guard let scope else { return jobs }
        return jobs.filter { $0.workspaceID == scope }
    }

    var scopedRuns: [RunRecord] {
        guard let scope else { return runs }
        return runs.filter { $0.workspaceID == scope }
    }

    func count(in workspaceID: String) -> Int {
        jobs.filter { $0.workspaceID == workspaceID }.count
    }

    func liveJobs(in workspaceID: String) -> [Automation] {
        jobs.filter { job in
            job.workspaceID == workspaceID && lastRun(for: job)?.isRunning == true
        }
    }

    func refreshList() async {
        do {
            async let j = Bridge.automations()
            async let r = Bridge.automationRuns()
            jobs = try await j
            runs = try await r
            #if os(macOS)
            RunNotifications.shared.settle(automations: runs)
            #endif
        } catch {
        }
    }

    func lastRun(for job: Automation) -> RunRecord? {
        if let id = job.lastRunID, let run = runs.first(where: { $0.id == id }) {
            return run
        }
        return runs.first { $0.jobId == job.id }
    }

    func runs(of job: Automation) -> [RunRecord] {
        runs.filter { $0.jobId == job.id }
    }

    var selectedRun: RunRecord? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    func dropOutOfScopeSelection() {
        if let scope, let id = selectedJobID,
           let job = jobs.first(where: { $0.id == id }),
           job.workspaceID != scope
        {
            selectedJobID = nil
            if selectedFocus == .job { selectedFocus = .none }
        }
        if let scope, let id = selectedRunID,
           let run = runs.first(where: { $0.id == id }),
           run.workspaceID != scope
        {
            selectedRunID = nil
            if selectedFocus == .run { selectedFocus = .none }
        }
    }

    var selectedJob: Automation? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    func selectJob(_ id: String) {
        selectedJobID = id
        selectedFocus = .job
        if let job = jobs.first(where: { $0.id == id }), let last = lastRun(for: job) {
            watch(last)
        }
    }

    func selectRun(_ run: RunRecord) {
        selectedJobID = run.jobId
        selectedFocus = .run
        watch(run)
    }

    func create(
        name: String,
        backend: String,
        model: String? = nil,
        effort: String? = nil,
        workspaceID: String,
        prompt: String,
        schedule: AutomationSchedule,
        budget: UInt64
    ) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isAutoCommitName(trimmed), var existing = autoCommitJob(in: workspaceID) {
            existing.backend = backend
            existing.model = model
            existing.effort = effort
            existing.prompt = prompt
            existing.schedule = schedule
            existing.budgetSeconds = budget
            existing.enabled = true
            await update(existing, announce: false)
            guard errorMessage == nil else { return }
            showNotice(L10n.text("apple.automationsmodel.updated_auto_commit_in_this_folder.90b44ff5"))
            selectJob(existing.id)
            return
        }
        let job = Automation(
            id: "", name: trimmed, backend: backend, model: model, effort: effort,
            workspaceID: workspaceID, prompt: prompt,
            schedule: schedule, budgetSeconds: budget, enabled: true,
            lastRunAtMs: nil, nextRunAtMs: nil, lastRunID: nil
        )
        if Self.isAutoCommitName(trimmed) {
            do {
                _ = try await Bridge.createAutomation(job)
                showNotice(L10n.text("apple.automationsmodel.0_will_run_1.0536f940", "\(trimmed)", "\(scheduleSummary(schedule))"))
                errorMessage = nil
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        if let pending = pendingCreate, !Self.sameCreateRequest(pending.job, job) {
            errorMessage = L10n.text("apple.automationsmodel.a_new_job_was_sent_and_is_not_confirmed_ye.97b65031")
            return
        }
        do {
            let operationID: String
            if let pending = pendingCreate, Self.sameCreateRequest(pending.job, job) {
                operationID = pending.operationID
            } else {
                operationID = "automation-create-\(UUID().uuidString)"
                pendingCreate = (operationID, job)
            }
            let outcome = try await Bridge.createAutomationOnce(job, operationID: operationID)
            await confirmCreate(outcome, name: trimmed, schedule: schedule)
        } catch {
            if let operationID = pendingCreate?.operationID,
               let outcome = try? await Bridge.automationCreationReceipt(operationID: operationID)
            {
                await confirmCreate(outcome, name: trimmed, schedule: schedule)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    var queueBudgetSeconds: UInt64? {
        if queueNoLimit { return 0 }
        if !savedQueueNoLimit, queueBudgetMinutes == savedQueueBudgetMinutes {
            return savedQueueBudgetSeconds
        }
        let trimmed = queueBudgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = UInt64(trimmed), minutes > 0, minutes <= UInt64.max / 60 else { return nil }
        return minutes * 60
    }

    func saveQueue() async {
        guard let budget = queueBudgetSeconds else {
            errorMessage = L10n.text("apple.automationsmodel.time_limit_must_be_a_whole_number_of_minut.490575e6")
            return
        }
        let maxTrimmed = queueMaxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let max = UInt32(maxTrimmed) else {
            errorMessage = L10n.text("apple.automationsmodel.max_concurrent_jobs_must_be_a_whole_number.5458c85d")
            return
        }
        do {
            applyQueue(try await Bridge.setAutomationQueue(
                defaultBudgetSeconds: budget,
                maxConcurrent: max
            ))
            showNotice(L10n.text("apple.automationsmodel.scheduler_saved.4e10688a"))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyQueue(_ queue: AutomationQueue) {
        savedQueueBudgetSeconds = queue.defaultBudgetSeconds
        queueNoLimit = queue.defaultBudgetSeconds == 0
        if queue.defaultBudgetSeconds > 0 {
            queueBudgetMinutes = String(max(1, queue.defaultBudgetSeconds / 60))
        }
        queueMaxConcurrent = String(queue.maxConcurrent)
        savedQueueBudgetMinutes = queueBudgetMinutes
        savedQueueNoLimit = queueNoLimit
        savedQueueMaxConcurrent = queueMaxConcurrent
        if let timezone = HostScheduleClock.resolved(queue.timezone) {
            schedulerTimezone = timezone
        }
    }

    func toggle(_ job: Automation) async {
        do {
            _ = try await Bridge.setAutomation(job.id, enabled: !job.enabled)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ job: Automation, announce: Bool = true) async {
        do {
            _ = try await Bridge.editAutomation(job, expectedRevision: job.revision)
            if announce {
                showNotice(L10n.text("apple.automationsmodel.saved_0.d851298f", "\(job.name)"))
            }
            errorMessage = nil
            await load()
        } catch {
            await load()
            errorMessage = error.localizedDescription
        }
    }

    var hasUnconfirmedCreate: Bool { pendingCreate != nil }
    var unconfirmedCreate: Automation? { pendingCreate?.job }

    func checkCreate() async {
        guard let pending = pendingCreate else { return }
        do {
            if let outcome = try await Bridge.automationCreationReceipt(operationID: pending.operationID) {
                await confirmCreate(outcome, name: pending.job.name, schedule: pending.job.schedule)
            } else {
                errorMessage = nil
                showNotice(L10n.text("apple.automationsmodel.the_computer_has_no_creation_receipt_yet_r.0bbb20f6"))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryCreate() async {
        guard let pending = pendingCreate else { return }
        do {
            let outcome = try await Bridge.createAutomationOnce(pending.job, operationID: pending.operationID)
            await confirmCreate(outcome, name: pending.job.name, schedule: pending.job.schedule)
        } catch {
            if let outcome = try? await Bridge.automationCreationReceipt(operationID: pending.operationID) {
                await confirmCreate(outcome, name: pending.job.name, schedule: pending.job.schedule)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func hasUnconfirmedLaunch(_ jobID: String) -> Bool {
        pendingLaunches[jobID] != nil
    }

    static func isConcurrentEdit(_ message: String?) -> Bool {
        message?.contains("This job changed since you opened it") == true
    }

    func run(_ job: Automation) async {
        let operationID = pendingLaunches[job.id] ?? "automation-run-\(UUID().uuidString)"
        pendingLaunches[job.id] = operationID
        do {
            let outcome = try await Bridge.runAutomationOnce(id: job.id, operationID: operationID)
            await confirmRun(outcome, job: job)
        } catch {
            if let outcome = try? await Bridge.automationRunReceipt(operationID: operationID) {
                await confirmRun(outcome, job: job)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func checkLaunch(_ job: Automation) async {
        guard let operationID = pendingLaunches[job.id] else { return }
        do {
            if let outcome = try await Bridge.automationRunReceipt(operationID: operationID) {
                await confirmRun(outcome, job: job)
            } else {
                errorMessage = nil
                showNotice(L10n.text("apple.automationsmodel.the_computer_has_no_run_receipt_yet_retry.bb1e0fd1"))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ run: RunRecord) async {
        do {
            try await Bridge.automationKill(runID: run.id)
            showNotice(L10n.text("apple.automationsmodel.stopped_0.6cebd065", "\(run.name)"))
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAutoCommit(
        workspaceID: String,
        workspaceName: String,
        backend: String,
        model: String?
    ) async {
        if var existing = autoCommitJob(in: workspaceID) {
            if lastRun(for: existing)?.isRunning == true {
                selectJob(existing.id)
                if let last = lastRun(for: existing) {
                    selectRun(last)
                }
                return
            }
            existing = AutoCommitJob.job(
                in: workspaceID,
                workspaceName: workspaceName,
                backend: backend,
                model: model,
                existing: existing
            )
            await update(existing, announce: false)
            if errorMessage != nil { return }
            guard let job = jobs.first(where: { $0.id == existing.id }) else { return }
            selectJob(job.id)
            await run(job)
            return
        }
        let draft = AutoCommitJob.job(
            in: workspaceID,
            workspaceName: workspaceName,
            backend: backend,
            model: model
        )
        do {
            let created = try await Bridge.createAutomation(draft)
            errorMessage = nil
            await load()
            selectJob(created.id)
            await run(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmCreate(
        _ outcome: AutomationCreationOutcome,
        name: String,
        schedule: AutomationSchedule
    ) async {
        pendingCreate = nil
        showNotice(L10n.text("apple.automationsmodel.0_will_run_1.0536f940", "\(name)", "\(scheduleSummary(schedule))"))
        errorMessage = nil
        await load()
        if let created = outcome.job {
            selectJob(created.id)
        } else if !outcome.jobID.isEmpty {
            selectJob(outcome.jobID)
        }
    }

    private func confirmRun(_ outcome: AutomationRunOutcome, job: Automation) async {
        pendingLaunches[job.id] = nil
        showNotice(L10n.text("apple.automationsmodel.started_0.8f95ec71", "\(job.name)"))
        errorMessage = nil
        await load()
        if let run = outcome.run, runs.contains(where: { $0.id == run.id }) {
            selectRun(run)
        } else if !outcome.runID.isEmpty, let run = runs.first(where: { $0.id == outcome.runID }) {
            selectRun(run)
        } else if let updated = outcome.job {
            if let id = updated.lastRunID, let run = runs.first(where: { $0.id == id }) {
                selectRun(run)
            } else if let last = lastRun(for: updated) ?? lastRun(for: job) {
                selectRun(last)
            }
        }
    }

    private static func sameCreateRequest(_ left: Automation, _ right: Automation) -> Bool {
        left.name == right.name
            && left.backend == right.backend
            && left.model == right.model
            && left.effort == right.effort
            && left.workspaceID == right.workspaceID
            && left.prompt == right.prompt
            && left.schedule == right.schedule
            && left.budgetSeconds == right.budgetSeconds
            && left.enabled == right.enabled
    }

    static func autoCommitPrompt(workspaceName: String) -> String {
        AutoCommitJob.prompt(workspaceName: workspaceName)
    }

    static func releasePrompt() -> String { AutomationTemplate.releasePrompt }

    func remove(_ job: Automation) async {
        do {
            try await Bridge.removeAutomation(job.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func watch(_ run: RunRecord) {
        stopPolling()
        selectedRunID = run.id
        watchingRunID = run.id
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
        guard isVisible, let live = selectedRun ?? liveRun else {
            stopPolling()
            return
        }
        if watchingRunID == nil || watchingRunID != live.id {
            watchingRunID = live.id
            transcriptText = ""
            transcriptOffset = 0
        }
        if live.isRunning {
            startPolling(live.id)
        } else {
            stopPolling()
            let id = live.id
            startCatchUp(id: id)
        }
    }

    private func startPolling(_ id: String) {
        guard isVisible else { return }
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
            await self?.fetchTranscriptUntilCaughtUp(id: id)
        }
    }

    private func stopPolling() {
        catchUpTask?.cancel()
        catchUpTask = nil
        pollTask?.cancel()
        pollTask = nil
        pollingID = nil
    }

    private func refreshRuns() async {
        do {
            let latest = try await Bridge.automationRuns()
            guard !Task.isCancelled, isVisible else { return }
            let before = runs.first { $0.id == watchingRunID }
            runs = latest
            let after = runs.first { $0.id == watchingRunID }
            if let before, let after, before.status != after.status, !after.isRunning {
                stopPolling()
                startCatchUp(id: after.id)
            }
        } catch {
        }
    }

    private func fetchTranscriptUntilCaughtUp(id: String) async {
        while !Task.isCancelled, isVisible, watchingRunID == id {
            let before = transcriptOffset
            await fetchTranscript(id: id)
            if watchingRunID != id { return }
            if transcriptOffset <= before { return }
        }
    }

    private func fetchTranscript(id: String) async {
        guard !Task.isCancelled, isVisible, watchingRunID == id else { return }
        do {
            let offset = transcriptOffset
            let chunk = try await Bridge.automationTranscript(id: id, offset: offset)
            guard !Task.isCancelled, isVisible, watchingRunID == id, transcriptOffset == offset else { return }
            if chunk.nextOffset < transcriptOffset {
                transcriptText = ""
                transcriptOffset = 0
                let again = try await Bridge.automationTranscript(id: id, offset: 0)
                guard !Task.isCancelled, isVisible, watchingRunID == id, transcriptOffset == 0 else { return }
                transcriptText = Self.capped(again.text)
                transcriptOffset = again.nextOffset
                return
            }
            if !chunk.text.isEmpty {
                transcriptText = Self.capped(transcriptText + chunk.text)
            }
            transcriptOffset = chunk.nextOffset
        } catch {
        }
    }

    private func showNotice(_ message: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        noticeMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeMessage = nil
        }
    }

    func scheduleSummary(_ s: AutomationSchedule) -> String {
        s.summary
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
