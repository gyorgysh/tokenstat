// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct SavedTaskCreation: Codable, Equatable, Sendable {
    var fields: TaskEditorDraft
    var needsDefault = true
    var pending: TaskCreationSubmission?
    var outcome: TaskCreationOutcome?
}

/// The submission is saved before it leaves the device. Receipt reads never
/// create work, and an explicit retry always repeats the original operation.
@MainActor @Observable
final class TaskCreationSession {
    let target: TaskEditorTarget
    let initialFolder: String
    let column: String
    var fields: TaskEditorDraft { didSet { scheduleSave() } }
    private(set) var saved: SavedTaskCreation
    private(set) var loaded = false
    private(set) var ready = false
    private(set) var working = false
    private(set) var canRetry = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var backends: [AgentBackend] = []
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var persistedFields: TaskEditorDraft?
    private(set) var otherDraft: WorkbenchDraftFile<SavedTaskCreation>.Record?
    private let service: any TaskCreationService
    private let storage: WorkbenchDraftFile<SavedTaskCreation>?
    private var diskRevision: String?
    private var defaultBudget: UInt64 = 10800
    private var initialized = false
    private var restoring = false
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeTask: Task<Void, Never>?

    init(target: TaskEditorTarget, workspaceID: String, column: String, scope: WorkReference.Scope?, hostIdentity: String?, service: (any TaskCreationService)? = nil, draftDirectory: URL? = nil) {
        self.target = target; self.initialFolder = workspaceID; self.column = column
        self.service = service ?? target
        let fields = TaskEditorDraft(workspaceID: workspaceID, budgetSeconds: 10800)
        self.fields = fields; saved = SavedTaskCreation(fields: fields)
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: workspaceID) + "new-task|" + column
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory, maximumBytes: 8 * 1024 * 1024)
        } else { storage = nil }
    }

    var canCreate: Bool { loaded && ready && !saved.needsDefault && !working && saved.pending == nil && saved.outcome == nil && otherDraft == nil && fields.validation == nil }
    var canEdit: Bool { loaded && initialized && !working && saved.pending == nil && saved.outcome == nil }

    func load() async {
        guard !working else { return }
        working = true
        defer { working = false }
        guard let storage else { errorMessage = "Waiting for this account and computer to be verified before saving work."; return }
        do {
            if !loaded {
                let record = try await storage.load()
                diskRevision = record?.revision
                if let record { restore(record.value); persistedFields = record.value.fields }
                loaded = true; initialized = true
                guard await persist() else { return }
            }
            ready = false
            guard try await service.supportsCreation() else {
                ready = false
                errorMessage = "Update this computer's tokenstat to create tasks from here. Your draft stays on this device."
                return
            }
            async let defaults = service.creationDefaults()
            async let agents = service.creationBackends()
            async let places = service.creationFolders()
            (defaultBudget, backends, folders) = try await (defaults, agents, places)
            if saved.needsDefault {
                let defaults = TaskEditorDraft(workspaceID: initialFolder, budgetSeconds: defaultBudget)
                restoring = true
                fields.budgetValue = defaults.budgetValue
                fields.budgetUnit = defaults.budgetUnit
                fields.noTimeLimit = defaults.noTimeLimit
                restoring = false
                saved.needsDefault = false
                guard await persist() else { return }
            }
            ready = true; errorMessage = nil
            if saved.pending != nil && saved.outcome == nil { await readReceipt() }
        } catch { errorMessage = error.localizedDescription }
    }

    func create() async {
        guard canCreate else { return }
        working = true
        defer { working = false }
        saved.pending = TaskCreationSubmission(operationID: UUID().uuidString, column: column, fields: fields)
        guard await persist() else { saved.pending = nil; return }
        await submit()
    }

    func check() async {
        guard loaded, !working, saved.pending != nil, saved.outcome == nil else { return }
        working = true
        defer { working = false }
        await readReceipt()
    }

    func retry() async {
        guard loaded, ready, !working, canRetry, saved.pending != nil, saved.outcome == nil, otherDraft == nil else { return }
        working = true
        defer { working = false }
        guard await persist() else { return }
        await submit()
    }

    private func submit() async {
        guard let pending = saved.pending else { return }
        canRetry = false; errorMessage = nil; noticeMessage = nil
        do { try await confirm(service.createTask(pending), operationID: pending.operationID) }
        catch { errorMessage = "The creation has not been confirmed. Check the computer before trying again. \(error.localizedDescription)" }
    }

    private func readReceipt() async {
        guard let pending = saved.pending else { return }
        canRetry = false; noticeMessage = nil
        do {
            if let outcome = try await service.taskCreationReceipt(operationID: pending.operationID) {
                try await confirm(outcome, operationID: pending.operationID)
            } else {
                canRetry = true
                errorMessage = nil
                noticeMessage = "The computer has no creation receipt yet. You can retry this same task safely."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func confirm(_ outcome: TaskCreationOutcome, operationID: String) async throws {
        guard outcome.operationID == operationID else { throw TaskEditorDraft.Invalid.fields("The computer returned a different creation. Check this task again.") }
        saved.outcome = outcome
        canRetry = false; errorMessage = nil; noticeMessage = nil
        _ = await persist()
        NotificationCenter.default.post(name: TaskEditorSession.didChange, object: target)
    }

    /// Only an acknowledged outcome can clear a submission. An older window
    /// cannot clear a newer operation or overwrite another window's draft.
    func finish(operationID: String) async -> Bool {
        guard !working, otherDraft == nil, saved.outcome?.operationID == operationID else { return false }
        working = true
        defer { working = false }
        let previous = saved
        restore(SavedTaskCreation(fields: TaskEditorDraft(workspaceID: initialFolder, budgetSeconds: defaultBudget)))
        if await persist() { errorMessage = nil; return true }
        restore(previous)
        return false
    }

    func resolveDiskConflict(keepMine: Bool) async {
        guard !working, let otherDraft, !keepMine || otherDraft.value.pending == nil else { return }
        working = true
        defer { working = false }
        diskRevision = otherDraft.revision
        self.otherDraft = nil
        if !keepMine { restore(otherDraft.value) }
        errorMessage = nil; canRetry = false
        guard await persist() else { return }
        if saved.pending != nil && saved.outcome == nil { await readReceipt() }
    }

    func flush() async { writeTask?.cancel(); _ = await persist() }
    private func restore(_ value: SavedTaskCreation) {
        restoring = true; saved = value; fields = value.fields; restoring = false
    }
    private func scheduleSave() {
        guard loaded, initialized, !restoring else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.flush()
        }
    }
    @discardableResult private func persist() async -> Bool {
        guard loaded, initialized, let storage, otherDraft == nil else { return false }
        while writing { await withCheckedContinuation { writeWaiters.append($0) } }
        guard otherDraft == nil else { return false }
        writing = true
        defer {
            writing = false
            let waiters = writeWaiters; writeWaiters.removeAll(); waiters.forEach { $0.resume() }
        }
        saved.fields = fields
        let snapshot = saved
        do {
            let record = try await storage.save(snapshot, expectedRevision: diskRevision)
            diskRevision = record.revision; persistedFields = snapshot.fields
            return true
        } catch {
            errorMessage = error.localizedDescription
            if case WorkbenchDraftFile<SavedTaskCreation>.Failure.changed = error { otherDraft = try? await storage.load() }
            return false
        }
    }
}

@MainActor enum TaskCreationSessions {
    private static var sessions: [String: TaskCreationSession] = [:]
    static func session(target: TaskEditorTarget, workspaceID: String, column: String) -> TaskCreationSession {
        let context = WorkSessionContext.shared
        let host = target.peer ?? context.localHostIdentity
        guard let scope = context.scope, let host else { return TaskCreationSession(target: target, workspaceID: workspaceID, column: column, scope: nil, hostIdentity: nil) }
        let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: workspaceID) + "new-task|" + column
        if let existing = sessions[key] { return existing }
        let created = TaskCreationSession(target: target, workspaceID: workspaceID, column: column, scope: scope, hostIdentity: host)
        sessions[key] = created
        return created
    }
}
