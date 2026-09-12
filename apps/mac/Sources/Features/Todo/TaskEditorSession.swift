// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct TaskEditSubmission: Codable, Equatable, Sendable {
    let revision: UInt64
    let draft: TaskEditorDraft
}

struct SavedTaskDraft: Codable, Equatable, Sendable {
    var baseline: TodoCard
    var fields: TaskEditorDraft
    var pending: TaskEditSubmission?
}

/// One owner per account, computer and task. A folder move keeps this identity.
@MainActor @Observable
final class TaskEditorSession {
    let target: TaskEditorTarget
    private(set) var saved: SavedTaskDraft
    var fields: TaskEditorDraft { didSet { scheduleSave() } }
    private(set) var current: TodoCard?
    private(set) var conflict = false
    private(set) var missing = false
    private(set) var loaded = false
    private(set) var working = false
    private(set) var errorMessage: String?
    private(set) var backends: [AgentBackend] = []
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var otherDraft: WorkbenchDraftFile<SavedTaskDraft>.Record?
    private(set) var persistedFields: TaskEditorDraft?
    private let storage: WorkbenchDraftFile<SavedTaskDraft>?
    private let service: any TaskEditorService
    private var diskRevision: String?
    private var writeTask: Task<Void, Never>?
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoring = false

    init(target: TaskEditorTarget, card: TodoCard, scope: WorkReference.Scope?, hostIdentity: String?, service: (any TaskEditorService)? = nil, draftDirectory: URL? = nil) {
        self.target = target
        self.service = service ?? target
        fields = TaskEditorDraft(card)
        saved = SavedTaskDraft(baseline: card, fields: TaskEditorDraft(card))
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: "") + "task|" + card.id
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory, maximumBytes: 4 * 1024 * 1024)
        } else { storage = nil }
    }

    var dirty: Bool { !fields.matches(saved.baseline) }
    var canSave: Bool { loaded && !working && !conflict && !missing && saved.baseline.revision != nil && otherDraft == nil && saved.pending == nil && fields.validation == nil && dirty }

    func load() async {
        if loaded { await refresh(); await loadOptions(); return }
        guard !loaded, !working else { return }
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
        } catch { errorMessage = error.localizedDescription; return }
        guard await service.supportsEditing() else {
            loaded = false
            errorMessage = "Update this computer's tokenstat to edit tasks from here."
            return
        }
        await readCurrent()
        await loadOptions()
    }

    private func loadOptions() async {
        do {
            async let availableBackends = service.taskBackends()
            async let availableFolders = service.taskFolders()
            (backends, folders) = try await (availableBackends, availableFolders)
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard loaded, !working else { return }
        working = true
        defer { working = false }
        await readCurrent()
    }

    private func readCurrent() async {
        do {
            current = try await service.task(id: saved.baseline.id)
            missing = current == nil
            guard let current else {
                errorMessage = "This task was deleted on the computer. Your draft is still here."
                return
            }
            guard current.revision != nil else {
                errorMessage = "This computer did not return the task's revision. Reload it before saving."
                return
            }
            errorMessage = nil
            conflict = current.revision != saved.baseline.revision && dirty
            if let pending = saved.pending {
                if current.revision != pending.revision && pending.draft.matches(current) {
                    saved.baseline = current
                    saved.pending = nil
                    conflict = false
                    errorMessage = nil
                    _ = await persist()
                } else {
                    // A timed-out edit may still arrive. Retrying the same base
                    // revision is safe: only one checked edit can win.
                    saved.pending = nil
                    conflict = current.revision != saved.baseline.revision
                    errorMessage = conflict ? nil : "The task has not changed. Your draft is ready to save again."
                    _ = await persist()
                }
            } else if current.revision != saved.baseline.revision {
                if dirty { conflict = true }
                else {
                    restore(SavedTaskDraft(baseline: current, fields: TaskEditorDraft(current)))
                    conflict = false
                    _ = await persist()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func save() async {
        guard canSave, let revision = saved.baseline.revision else { return }
        working = true
        defer { working = false }
        let submission = TaskEditSubmission(revision: revision, draft: fields)
        saved.pending = submission
        guard await persist() else { saved.pending = nil; return }
        do {
            let result = try await service.edit(id: saved.baseline.id, revision: revision, draft: submission.draft)
            saved.baseline = result
            saved.pending = nil
            current = result
            errorMessage = nil
            _ = await persist()
            NotificationCenter.default.post(name: Self.didChange, object: target)
        } catch {
            errorMessage = "Check the saved task before trying again. Your draft is still here. \(error.localizedDescription)"
        }
    }

    func resolveConflict(keepMine: Bool) async {
        guard !working, conflict, let current, saved.pending == nil else { return }
        saved.baseline = current
        if !keepMine { restoring = true; fields = TaskEditorDraft(current); restoring = false }
        conflict = false
        errorMessage = nil
        _ = await persist()
    }

    func resolveDiskConflict(keepMine: Bool) async {
        guard !working, let otherDraft else { return }
        // An unresolved submission belongs to the saved draft and must be
        // recovered before either window can replace it.
        guard !keepMine || otherDraft.value.pending == nil else { return }
        diskRevision = otherDraft.revision
        self.otherDraft = nil
        if !keepMine { restore(otherDraft.value) }
        _ = await persist()
        await refresh()
    }

    func flush() async { writeTask?.cancel(); _ = await persist() }

    private func restore(_ value: SavedTaskDraft) {
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
            if case WorkbenchDraftFile<SavedTaskDraft>.Failure.changed = error {
                otherDraft = try? await storage.load()
            }
            return false
        }
    }

    static let didChange = Notification.Name("tokenstat.taskDidChange")
}

@MainActor enum TaskEditorSessions {
    private static var sessions: [String: TaskEditorSession] = [:]
    static func session(target: TaskEditorTarget, card: TodoCard) -> TaskEditorSession {
        let context = WorkSessionContext.shared
        let host = target.peer ?? context.localHostIdentity
        guard let scope = context.scope, let host else { return TaskEditorSession(target: target, card: card, scope: nil, hostIdentity: nil) }
        let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: "") + "task|" + card.id
        if let existing = sessions[key] { return existing }
        let created = TaskEditorSession(target: target, card: card, scope: scope, hostIdentity: host)
        sessions[key] = created
        return created
    }
}
