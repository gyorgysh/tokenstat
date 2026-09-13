// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct AutomationCreationSubmission: Codable, Equatable, Sendable {
    let operationID: String
    let fields: AutomationEditorDraft
    enum CodingKeys: String, CodingKey { case operationID = "operationId", fields }
}

struct AutomationEditSubmission: Codable, Equatable, Sendable {
    let revision: UInt64
    let draft: AutomationEditorDraft
}

struct SavedAutomationDraft: Codable, Equatable, Sendable {
    var jobID: String?
    var baseline: Automation?
    var fields: AutomationEditorDraft
    var pendingCreate = false
    var pendingCreation: AutomationCreationSubmission? = nil
    var pendingEdit: AutomationEditSubmission? = nil
    var created: Automation? = nil

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case baseline, fields, pendingCreate, pendingCreation, pendingEdit, created
    }
}

/// One owner per account, computer, folder and job. A new job uses a folder key.
@MainActor @Observable
final class AutomationEditorSession {
    let target: AutomationEditorTarget
    let workspaceID: String
    let folderName: String
    let lockedFolder: Bool
    private(set) var saved: SavedAutomationDraft
    var fields: AutomationEditorDraft { didSet { scheduleSave() } }
    private(set) var current: Automation?
    private(set) var missing = false
    private(set) var conflict = false
    private(set) var loaded = false
    private(set) var working = false
    private(set) var supportsReceipts = false
    private(set) var canRetryCreate = false
    private(set) var liveRun = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var backends: [AgentBackend] = []
    /// IANA name of the host scheduler clock. Empty until queue answers.
    private(set) var schedulerTimezone: String = ""
    private(set) var otherDraft: WorkbenchDraftFile<SavedAutomationDraft>.Record?
    private(set) var persistedFields: AutomationEditorDraft?
    private let service: any AutomationEditorService
    private let storage: WorkbenchDraftFile<SavedAutomationDraft>?
    private var diskRevision: String?
    private var writeTask: Task<Void, Never>?
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoring = false
    private var appliedDefaultBudget = false

    init(
        target: AutomationEditorTarget,
        workspaceID: String,
        folderName: String,
        existing: Automation? = nil,
        lockedFolder: Bool = true,
        scope: WorkReference.Scope?,
        hostIdentity: String?,
        service: (any AutomationEditorService)? = nil,
        draftDirectory: URL? = nil
    ) {
        self.target = target
        self.workspaceID = workspaceID
        self.folderName = folderName
        self.lockedFolder = lockedFolder
        self.service = service ?? target
        let fields = existing.map(AutomationEditorDraft.init) ?? AutomationEditorDraft(workspaceID: workspaceID)
        self.fields = fields
        saved = SavedAutomationDraft(jobID: existing?.id, baseline: existing, fields: fields)
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let suffix = existing.map { "automation|" + $0.id } ?? "new-automation"
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: workspaceID) + suffix
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory, maximumBytes: 4 * 1024 * 1024)
        } else {
            storage = nil
        }
    }

    var isCreate: Bool { saved.jobID == nil && saved.created == nil }
    var dirty: Bool {
        if let baseline = saved.baseline { return !fields.matches(baseline) }
        return !fields.name.isEmpty || !fields.prompt.isEmpty || fields.scheduleKind != .once
    }
    var creating: Bool { saved.pendingCreate || saved.pendingCreation != nil }
    var canSave: Bool {
        loaded && !working && !missing && !conflict && otherDraft == nil && !creating
            && saved.pendingEdit == nil && saved.created == nil && fields.validation == nil && dirty
    }
    var canCreate: Bool {
        isCreate && loaded && !working && otherDraft == nil && !creating
            && saved.created == nil && fields.validation == nil
    }

    func load() async {
        if loaded {
            await refresh()
            await loadOptions()
            await loadQueue()
            if creating, saved.created == nil { await readCreation() }
            return
        }
        guard !working else { return }
        working = true
        defer { working = false }
        guard let storage else {
            errorMessage = "Waiting for this account and computer to be verified before saving work."
            return
        }
        do {
            let record = try await storage.load()
            diskRevision = record?.revision
            persistedFields = record?.value.fields
            if let record { restore(record.value) }
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        supportsReceipts = await service.supportsReceipts()
        await loadOptions()
        await loadQueue()
        lockFolderIfNeeded()
        await readCurrent()
        if isCreate, fields.backend.isEmpty, let agent = defaultBackend() {
            restoring = true
            fields.backend = agent.id
            restoring = false
        }
        _ = await persist()
        if creating, saved.created == nil { await readCreation() }
    }

    func refresh() async {
        guard loaded, !working else { return }
        working = true
        defer { working = false }
        supportsReceipts = await service.supportsReceipts()
        await loadOptions()
        await readCurrent()
    }

    func save() async {
        if isCreate {
            await create()
            return
        }
        guard canSave, let baseline = saved.baseline ?? current else { return }
        working = true
        defer { working = false }
        lockFolderIfNeeded()
        let job: Automation
        do {
            job = try fields.makeJob(
                id: baseline.id,
                enabled: baseline.enabled,
                lastRunAtMs: baseline.lastRunAtMs,
                lastRunID: baseline.lastRunID,
                revision: baseline.revision
            )
        } catch {
            errorMessage = Self.display(error)
            return
        }
        errorMessage = nil
        if supportsReceipts {
            let submission = AutomationEditSubmission(revision: baseline.revision, draft: fields)
            saved.pendingEdit = submission
            guard await persist() else {
                saved.pendingEdit = nil
                return
            }
            do {
                let updated = try await service.editAutomation(job, revision: submission.revision)
                await applySaved(updated)
            } catch {
                await recoverEdit(error)
            }
            return
        }
        do {
            let updated = try await service.updateAutomation(job)
            await applySaved(updated)
        } catch {
            errorMessage = Self.display(error)
        }
    }

    func create() async {
        guard canCreate else { return }
        working = true
        defer { working = false }
        lockFolderIfNeeded()
        let job: Automation
        do {
            job = try fields.makeJob(id: "", enabled: true)
        } catch {
            errorMessage = Self.display(error)
            return
        }
        if supportsReceipts {
            let submission = AutomationCreationSubmission(
                operationID: "automation-create-\(UUID().uuidString)",
                fields: fields
            )
            saved.pendingCreation = submission
            saved.pendingCreate = true
            canRetryCreate = false
            guard await persist() else {
                saved.pendingCreation = nil
                saved.pendingCreate = false
                return
            }
            await submitCreation(submission)
            return
        }
        saved.pendingCreate = true
        guard await persist() else {
            saved.pendingCreate = false
            return
        }
        do {
            let created = try await service.createAutomation(job)
            await confirmCreated(created)
        } catch {
            if Self.isUncertain(error) {
                errorMessage = "The computer did not confirm this job. Check this folder's automations before creating another."
            } else {
                saved.pendingCreate = false
                errorMessage = Self.display(error)
                _ = await persist()
            }
        }
    }

    func checkCreated() async {
        guard loaded, !working, creating, saved.created == nil else { return }
        working = true
        defer { working = false }
        await readCreation()
    }

    func retryCreate() async {
        guard loaded, !working, canRetryCreate, let submission = saved.pendingCreation, saved.created == nil, otherDraft == nil else { return }
        working = true
        defer { working = false }
        guard await persist() else { return }
        await submitCreation(submission)
    }

    /// Clears a finished create so the next New automation is a blank job.
    func finishCreated() async -> Automation? {
        guard let created = saved.created else { return nil }
        restoring = true
        let fresh = AutomationEditorDraft(workspaceID: workspaceID, backend: defaultBackend()?.id ?? "")
        fields = fresh
        saved = SavedAutomationDraft(jobID: nil, baseline: nil, fields: fresh)
        restoring = false
        appliedDefaultBudget = false
        noticeMessage = nil
        errorMessage = nil
        missing = false
        conflict = false
        canRetryCreate = false
        current = nil
        _ = await persist()
        return created
    }

    func resolveConflict(keepMine: Bool) async {
        guard !working, conflict, let current, saved.pendingEdit == nil else { return }
        saved.baseline = current
        saved.jobID = current.id
        if !keepMine {
            restoring = true
            fields = AutomationEditorDraft(current)
            restoring = false
        }
        conflict = false
        errorMessage = nil
        _ = await persist()
    }

    func resolveDiskConflict(keepMine: Bool) async {
        guard !working, let otherDraft else { return }
        let other = otherDraft.value
        guard !keepMine || (!other.pendingCreate && other.pendingCreation == nil && other.pendingEdit == nil) else { return }
        diskRevision = otherDraft.revision
        self.otherDraft = nil
        if !keepMine { restore(other) }
        _ = await persist()
        if creating, saved.created == nil { await readCreation() }
    }

    func flush() async {
        writeTask?.cancel()
        _ = await persist()
    }

    private func lockFolderIfNeeded() {
        guard lockedFolder, fields.workspaceID != workspaceID else { return }
        restoring = true
        fields.workspaceID = workspaceID
        restoring = false
    }

    func pickerBackends() -> [AgentBackend] {
        var values = backends
        if !fields.backend.isEmpty, !values.contains(where: { $0.id == fields.backend }) {
            values.append(AgentBackend(id: fields.backend, label: "\(fields.backend) · Unavailable", command: fields.backend))
        }
        if let at = values.firstIndex(where: { $0.id == "sh" }) {
            values.append(values.remove(at: at))
        }
        return values
    }

    private func defaultBackend() -> AgentBackend? {
        pickerBackends().first { $0.id != "sh" } ?? pickerBackends().first
    }

    private func loadOptions() async {
        do {
            backends = try await service.automationBackends()
        } catch {
            errorMessage = Self.display(error)
        }
        do {
            let running = try await service.runningJobIDs()
            if let id = saved.jobID ?? saved.baseline?.id {
                liveRun = running.contains(id)
            } else {
                liveRun = false
            }
        } catch {
            liveRun = false
        }
    }

    private func loadQueue() async {
        do {
            let queue = try await service.automationQueue()
            if let timezone = HostScheduleClock.resolved(queue.timezone) {
                schedulerTimezone = timezone
            }
            if isCreate, !appliedDefaultBudget {
                restoring = true
                fields.noTimeLimit = queue.defaultBudgetSeconds == 0
                if queue.defaultBudgetSeconds > 0 {
                    fields.budgetMinutes = String(max(1, queue.defaultBudgetSeconds / 60))
                }
                restoring = false
                appliedDefaultBudget = true
                _ = await persist()
            }
        } catch {
            if isCreate { appliedDefaultBudget = true }
        }
    }

    private func readCurrent() async {
        guard let id = saved.jobID else {
            missing = false
            current = nil
            conflict = false
            return
        }
        do {
            current = try await service.automation(id: id)
            missing = current == nil
            if missing {
                errorMessage = "This job was deleted on the computer. Your draft is still here."
                conflict = false
                return
            }
            guard let current else { return }
            if errorMessage?.hasPrefix("This job was deleted") == true {
                errorMessage = nil
            }
            if supportsReceipts {
                await reconcileChecked(current)
            } else if let baseline = saved.baseline, !fields.matches(baseline), !fields.matches(current) {
                noticeMessage = "This job also changed on the computer. Saving overwrites that copy."
            }
        } catch {
            errorMessage = Self.display(error)
        }
    }

    private func reconcileChecked(_ current: Automation) async {
        conflict = current.revision != saved.baseline?.revision && dirty
        if let pending = saved.pendingEdit {
            if current.revision != pending.revision && pending.draft.matches(current) {
                saved.baseline = current
                saved.pendingEdit = nil
                conflict = false
                errorMessage = nil
                _ = await persist()
            } else {
                saved.pendingEdit = nil
                conflict = current.revision != saved.baseline?.revision
                errorMessage = conflict ? nil : "The job has not changed. Your draft is ready to save again."
                _ = await persist()
            }
        } else if current.revision != saved.baseline?.revision {
            if dirty {
                conflict = true
            } else {
                restore(SavedAutomationDraft(
                    jobID: current.id,
                    baseline: current,
                    fields: AutomationEditorDraft(current),
                    pendingCreate: saved.pendingCreate,
                    pendingCreation: saved.pendingCreation,
                    pendingEdit: nil,
                    created: saved.created
                ))
                conflict = false
                _ = await persist()
            }
        }
    }

    private func submitCreation(_ submission: AutomationCreationSubmission) async {
        canRetryCreate = false
        errorMessage = nil
        noticeMessage = nil
        let job: Automation
        do {
            job = try submission.fields.makeJob(id: "", enabled: true)
        } catch {
            errorMessage = Self.display(error)
            return
        }
        do {
            try await confirmCreation(
                service.createAutomationOnce(job, operationID: submission.operationID),
                operationID: submission.operationID
            )
        } catch {
            if let outcome = try? await service.automationCreationReceipt(operationID: submission.operationID) {
                try? await confirmCreation(outcome, operationID: submission.operationID)
                return
            }
            if Self.isUncertain(error) {
                canRetryCreate = true
                errorMessage = "The computer did not confirm this job. Check creation before making another."
            } else {
                saved.pendingCreate = false
                saved.pendingCreation = nil
                canRetryCreate = false
                errorMessage = Self.display(error)
                _ = await persist()
            }
        }
    }

    private func readCreation() async {
        if supportsReceipts, let submission = saved.pendingCreation {
            canRetryCreate = false
            noticeMessage = nil
            do {
                if let outcome = try await service.automationCreationReceipt(operationID: submission.operationID) {
                    try await confirmCreation(outcome, operationID: submission.operationID)
                } else {
                    canRetryCreate = true
                    errorMessage = nil
                    noticeMessage = "The computer has no creation receipt yet. You can retry this same job safely."
                }
            } catch {
                errorMessage = Self.display(error)
            }
            return
        }
        do {
            let jobs = try await service.automations()
            let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = fields.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = jobs.first {
                $0.workspaceID == fields.workspaceID
                    && $0.name == name
                    && $0.prompt == prompt
            }
            if let match {
                await confirmCreated(match)
            } else {
                errorMessage = "This job is not in the folder yet. It may still arrive, or it may never have been created. Do not create another until you have checked."
            }
        } catch {
            errorMessage = Self.display(error)
        }
    }

    private func confirmCreation(_ outcome: AutomationCreationOutcome, operationID: String) async throws {
        guard outcome.operationID == operationID else {
            throw AutomationEditorDraft.Invalid.fields("The computer returned a different creation. Check this job again.")
        }
        saved.pendingCreate = false
        saved.pendingCreation = nil
        canRetryCreate = false
        saved.created = outcome.job
        saved.jobID = outcome.jobID
        saved.baseline = outcome.job
        errorMessage = nil
        if let job = outcome.job {
            restoring = true
            fields = AutomationEditorDraft(job)
            restoring = false
            announceCreated(job)
        } else {
            missing = true
            noticeMessage = "This job was created and then removed from the folder."
        }
        _ = await persist()
        NotificationCenter.default.post(name: Self.didChange, object: target)
    }

    private func confirmCreated(_ created: Automation) async {
        saved.pendingCreate = false
        saved.pendingCreation = nil
        canRetryCreate = false
        saved.created = created
        saved.jobID = created.id
        saved.baseline = created
        restoring = true
        fields = AutomationEditorDraft(created)
        restoring = false
        errorMessage = nil
        announceCreated(created)
        _ = await persist()
        NotificationCenter.default.post(name: Self.didChange, object: target)
    }

    private func announceCreated(_ created: Automation) {
        if let place = HostScheduleClock.place(schedulerTimezone) {
            noticeMessage = "\(created.name) will run \(created.schedule.summary) in \(place)."
        } else {
            noticeMessage = "\(created.name) will run \(created.schedule.summary)."
        }
    }

    private func applySaved(_ updated: Automation) async {
        saved.baseline = updated
        saved.jobID = updated.id
        saved.pendingEdit = nil
        conflict = false
        restoring = true
        fields = AutomationEditorDraft(updated)
        restoring = false
        noticeMessage = "Saved \(updated.name)."
        _ = await persist()
        NotificationCenter.default.post(name: Self.didChange, object: target)
    }

    private func recoverEdit(_ error: Error) async {
        let id = saved.jobID ?? saved.baseline?.id
        if let id, let current = try? await service.automation(id: id) {
            self.current = current
            if let pending = saved.pendingEdit, pending.draft.matches(current) {
                await applySaved(current)
                return
            }
            if current.revision != saved.baseline?.revision {
                saved.pendingEdit = nil
                conflict = true
                errorMessage = nil
                noticeMessage = nil
                _ = await persist()
                return
            }
        }
        errorMessage = "Check the saved job before trying again. Your draft is still here. \(Self.display(error))"
    }

    private func restore(_ value: SavedAutomationDraft) {
        restoring = true
        saved = value
        fields = value.fields
        restoring = false
    }

    private func scheduleSave() {
        guard loaded, !restoring else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.flush()
        }
    }

    @discardableResult
    private func persist() async -> Bool {
        guard loaded, let storage, otherDraft == nil else { return false }
        while writing { await withCheckedContinuation { writeWaiters.append($0) } }
        guard otherDraft == nil else { return false }
        writing = true
        defer {
            writing = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        saved.fields = fields
        let snapshot = saved
        do {
            let record = try await storage.save(snapshot, expectedRevision: diskRevision)
            diskRevision = record.revision
            persistedFields = snapshot.fields
            return true
        } catch {
            errorMessage = error.localizedDescription
            if case WorkbenchDraftFile<SavedAutomationDraft>.Failure.changed = error {
                otherDraft = try? await storage.load()
            }
            return false
        }
    }

    static let didChange = Notification.Name("tokenstat.automationDidChange")

    static func isUncertain(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("disconnected")
            || lower.contains("cancelled")
            || lower.contains("canceled")
            || lower.contains("no_such_peer")
            || lower.contains("not on the tunnel")
            || lower.contains("tunnel is not connected")
            || lower.contains("tunnel disconnected")
    }

    static func display(_ error: Error) -> String {
        error.localizedDescription
    }
}

@MainActor enum AutomationEditorSessions {
    private static var sessions: [String: AutomationEditorSession] = [:]

    static func session(
        target: AutomationEditorTarget,
        workspaceID: String,
        folderName: String,
        existing: Automation? = nil,
        lockedFolder: Bool = true
    ) -> AutomationEditorSession {
        let context = WorkSessionContext.shared
        let host = target.peer ?? context.localHostIdentity
        guard let scope = context.scope, let host else {
            return AutomationEditorSession(
                target: target, workspaceID: workspaceID, folderName: folderName,
                existing: existing, lockedFolder: lockedFolder, scope: nil, hostIdentity: nil
            )
        }
        let suffix = existing.map { "automation|" + $0.id } ?? "new-automation"
        let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: workspaceID) + suffix
        if let existingSession = sessions[key] { return existingSession }
        let created = AutomationEditorSession(
            target: target, workspaceID: workspaceID, folderName: folderName,
            existing: existing, lockedFolder: lockedFolder, scope: scope, hostIdentity: host
        )
        sessions[key] = created
        return created
    }
}
