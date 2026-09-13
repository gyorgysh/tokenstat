// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct SavedAutomationDraft: Codable, Equatable, Sendable {
    var jobID: String?
    var baseline: Automation?
    var fields: AutomationEditorDraft
    var pendingCreate = false
    var created: Automation? = nil

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case baseline, fields, pendingCreate, created
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
    private(set) var loaded = false
    private(set) var working = false
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
    var canSave: Bool {
        loaded && !working && !missing && otherDraft == nil && saved.pendingCreate == false
            && saved.created == nil && fields.validation == nil && dirty
    }
    var canCreate: Bool {
        isCreate && loaded && !working && otherDraft == nil && saved.pendingCreate == false
            && saved.created == nil && fields.validation == nil
    }

    func load() async {
        if loaded {
            await refresh()
            await loadOptions()
            await loadQueue()
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
    }

    func refresh() async {
        guard loaded, !working else { return }
        working = true
        defer { working = false }
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
        do {
            let job = try fields.makeJob(
                id: baseline.id,
                enabled: baseline.enabled,
                lastRunAtMs: baseline.lastRunAtMs,
                lastRunID: baseline.lastRunID
            )
            errorMessage = nil
            let updated = try await service.updateAutomation(job)
            saved.baseline = updated
            saved.jobID = updated.id
            restoring = true
            fields = AutomationEditorDraft(updated)
            restoring = false
            noticeMessage = "Saved \(updated.name)."
            _ = await persist()
            NotificationCenter.default.post(name: Self.didChange, object: target)
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
        saved.pendingCreate = true
        guard await persist() else {
            saved.pendingCreate = false
            return
        }
        do {
            let created = try await service.createAutomation(job)
            saved.pendingCreate = false
            saved.created = created
            saved.jobID = created.id
            saved.baseline = created
            restoring = true
            fields = AutomationEditorDraft(created)
            restoring = false
            errorMessage = nil
            if let place = HostScheduleClock.place(schedulerTimezone) {
                noticeMessage = "\(created.name) will run \(created.schedule.summary) in \(place)."
            } else {
                noticeMessage = "\(created.name) will run \(created.schedule.summary)."
            }
            _ = await persist()
            NotificationCenter.default.post(name: Self.didChange, object: target)
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
        guard loaded, !working, saved.pendingCreate, saved.created == nil else { return }
        working = true
        defer { working = false }
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
                saved.pendingCreate = false
                saved.created = match
                saved.jobID = match.id
                saved.baseline = match
                errorMessage = nil
                noticeMessage = "\(match.name) is in this folder."
                _ = await persist()
                NotificationCenter.default.post(name: Self.didChange, object: target)
            } else {
                errorMessage = "This job is not in the folder yet. It may still arrive, or it may never have been created. Do not create another until you have checked."
            }
        } catch {
            errorMessage = Self.display(error)
        }
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
        current = nil
        _ = await persist()
        return created
    }

    func resolveDiskConflict(keepMine: Bool) async {
        guard !working, let otherDraft else { return }
        guard !keepMine || otherDraft.value.pendingCreate == false else { return }
        diskRevision = otherDraft.revision
        self.otherDraft = nil
        if !keepMine { restore(otherDraft.value) }
        _ = await persist()
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
            if errorMessage == nil { errorMessage = nil }
        } catch {
            errorMessage = Self.display(error)
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
            return
        }
        do {
            current = try await service.automation(id: id)
            missing = current == nil
            if missing {
                errorMessage = "This job was deleted on the computer. Your draft is still here."
                return
            }
            if let current, let baseline = saved.baseline, !fields.matches(baseline), !fields.matches(current) {
                // A newer host copy exists. Keep the draft and say so. Overwrite
                // is an explicit save, which is the P3.1 contract. Revision
                // checking is P3.6.
                noticeMessage = "This job also changed on the computer. Saving overwrites that copy."
            } else if errorMessage?.hasPrefix("This job was deleted") == true {
                errorMessage = nil
            }
        } catch {
            errorMessage = Self.display(error)
        }
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
