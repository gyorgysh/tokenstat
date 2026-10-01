// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct TaskEditSubmission: Codable, Equatable, Sendable {
    let revision: UInt64
    let draft: TaskEditorDraft
}

struct TaskRunSubmission: Codable, Equatable, Sendable {
    let operationID: String
    let cardID: String
    let revision: UInt64
    let placement: TaskRunPlacement

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case cardID = "cardId"
        case revision
        case placement
        /// Drafts written before the rename used the property spelling.
        case operationIDLegacy = "operationID"
        case cardIDLegacy = "cardID"
    }

    /// Reads either key spelling and writes the new one, so an in-flight run
    /// survives an update that lands between launch and receipt.
    init(operationID: String, cardID: String, revision: UInt64, placement: TaskRunPlacement) {
        self.operationID = operationID
        self.cardID = cardID
        self.revision = revision
        self.placement = placement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let operationID = try c.decodeIfPresent(String.self, forKey: .operationID)
            ?? c.decodeIfPresent(String.self, forKey: .operationIDLegacy) else {
            throw DecodingError.keyNotFound(
                CodingKeys.operationID,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: L10n.text("apple.taskeditorsession.missing_operationid.d2e51333")))
        }
        guard let cardID = try c.decodeIfPresent(String.self, forKey: .cardID)
            ?? c.decodeIfPresent(String.self, forKey: .cardIDLegacy) else {
            throw DecodingError.keyNotFound(
                CodingKeys.cardID,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: L10n.text("apple.taskeditorsession.missing_cardid.692ca690")))
        }
        self.operationID = operationID
        self.cardID = cardID
        revision = try c.decode(UInt64.self, forKey: .revision)
        placement = try c.decode(TaskRunPlacement.self, forKey: .placement)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(cardID, forKey: .cardID)
        try c.encode(revision, forKey: .revision)
        try c.encode(placement, forKey: .placement)
    }
}

/// Enough to reopen the same host terminal after the editor is dismissed.
struct TaskLiveTerminal: Codable, Equatable, Sendable {
    var runID: String
    var ptyID: String

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case ptyID = "ptyId"
        /// Drafts written before the rename used the property spelling.
        case runIDLegacy = "runID"
        case ptyIDLegacy = "ptyID"
    }

    init(runID: String, ptyID: String) {
        self.runID = runID
        self.ptyID = ptyID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let runID = try c.decodeIfPresent(String.self, forKey: .runID)
            ?? c.decodeIfPresent(String.self, forKey: .runIDLegacy) else {
            throw DecodingError.keyNotFound(
                CodingKeys.runID,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: L10n.text("apple.taskeditorsession.missing_runid.de9644b6")))
        }
        guard let ptyID = try c.decodeIfPresent(String.self, forKey: .ptyID)
            ?? c.decodeIfPresent(String.self, forKey: .ptyIDLegacy) else {
            throw DecodingError.keyNotFound(
                CodingKeys.ptyID,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: L10n.text("apple.taskeditorsession.missing_ptyid.f2d299fc")))
        }
        self.runID = runID
        self.ptyID = ptyID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runID, forKey: .runID)
        try c.encode(ptyID, forKey: .ptyID)
    }
}

struct SavedTaskDraft: Codable, Equatable, Sendable {
    var baseline: TodoCard
    var fields: TaskEditorDraft
    var pending: TaskEditSubmission?
    var pendingRun: TaskRunSubmission? = nil
    var liveTerminal: TaskLiveTerminal? = nil
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
    private(set) var supportsExecution = false
    private(set) var lastRun: TaskRunOutcome?
    private(set) var errorMessage: String?
    private(set) var backends: [AgentBackend] = []
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var otherDraft: WorkbenchDraftFile<SavedTaskDraft>.Record?
    private(set) var persistedFields: TaskEditorDraft?
    private let storage: WorkbenchDraftFile<SavedTaskDraft>?
    private let service: any TaskEditorService
    private let runService: any TaskRunService
    private var diskRevision: String?
    private var writeTask: Task<Void, Never>?
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoring = false

    init(target: TaskEditorTarget, card: TodoCard, scope: WorkReference.Scope?, hostIdentity: String?, service: (any TaskEditorService)? = nil, runService: (any TaskRunService)? = nil, draftDirectory: URL? = nil) {
        self.target = target
        self.service = service ?? target
        self.runService = runService ?? target
        fields = TaskEditorDraft(card)
        saved = SavedTaskDraft(baseline: card, fields: TaskEditorDraft(card))
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: "") + "task|" + card.id
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory, maximumBytes: 4 * 1024 * 1024)
        } else { storage = nil }
    }

    var dirty: Bool { !fields.matches(saved.baseline) }
    var canSave: Bool { loaded && !working && !conflict && !missing && saved.baseline.revision != nil && otherDraft == nil && saved.pending == nil && fields.validation == nil && dirty }
    /// Why this saved card cannot start. Nil means the host-side launch checks
    /// that we can see from here are satisfied. Save still happens first.
    var runReadiness: String? {
        guard loaded else { return nil }
        let card = saved.baseline
        if card.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.text("apple.taskeditorsession.assign_a_folder_before_running_this_task.6d7e591f")
        }
        if let folder = folders.first(where: { $0.id == card.workspaceID }), folder.exists == false {
            return L10n.text("apple.taskeditorsession.this_folder_is_no_longer_available_on_the.9a90a747")
        }
        if !folders.isEmpty && !folders.contains(where: { $0.id == card.workspaceID }) {
            return L10n.text("apple.taskeditorsession.this_folder_is_no_longer_available_on_the.9a90a747")
        }
        if card.backend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.text("apple.taskeditorsession.choose_an_agent_before_running_this_task.8c283f81")
        }
        if card.promptForRun.isEmpty {
            return L10n.text("apple.taskeditorsession.write_a_prompt_before_running_this_task.756d3037")
        }
        return nil
    }
    var canRun: Bool {
        supportsExecution && loaded && !working && !dirty && !conflict && !missing
            && saved.baseline.revision != nil && saved.pending == nil && saved.pendingRun == nil
            && otherDraft == nil && saved.baseline.delegate?.isRunning != true
            && runReadiness == nil
    }
    var canStop: Bool {
        supportsExecution && !working && saved.pending == nil && saved.pendingRun == nil
            && saved.baseline.delegate.map { ["starting", "queued", "running"].contains($0.status) } == true
    }

    func load() async {
        if loaded {
            await refresh()
            await loadOptions()
            supportsExecution = await runService.supportsTaskExecution()
            if saved.pendingRun != nil { await reconcileRun() }
            return
        }
        guard !loaded, !working else { return }
        working = true
        defer { working = false }
        guard let storage else {
            errorMessage = L10n.text("apple.taskeditorsession.waiting_for_this_account_and_computer_to_b.f97b4242")
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
            errorMessage = L10n.text("apple.taskeditorsession.update_this_computer_s_tokenstat_to_edit_t.ce8eb555")
            return
        }
        await readCurrent()
        await loadOptions()
        supportsExecution = await runService.supportsTaskExecution()
        working = false
        if saved.pendingRun != nil { await reconcileRun() }
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
                errorMessage = L10n.text("apple.taskeditorsession.this_task_was_deleted_on_the_computer_your.d9041f3d")
                return
            }
            guard current.revision != nil else {
                errorMessage = L10n.text("apple.taskeditorsession.this_computer_did_not_return_the_task_s_re.ec042ca5")
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
                    errorMessage = conflict ? nil : L10n.text("apple.taskeditorsession.the_task_has_not_changed_your_draft_is_rea.c2632d0f")
                    _ = await persist()
                }
            } else if current.revision != saved.baseline.revision {
                if dirty { conflict = true }
                else {
                    restore(SavedTaskDraft(
                        baseline: current,
                        fields: TaskEditorDraft(current),
                        pending: nil,
                        pendingRun: saved.pendingRun,
                        liveTerminal: matchingLiveTerminal(current)
                    ))
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
            errorMessage = L10n.text("apple.taskeditorsession.check_the_saved_task_before_trying_again_y.5af9adad", "\(error.localizedDescription)")
        }
    }

    func run(_ placement: TaskRunPlacement) async -> TaskRunOutcome? {
        guard canRun, let revision = saved.baseline.revision else { return nil }
        let submission = TaskRunSubmission(
            operationID: "task-run-\(UUID().uuidString)",
            cardID: saved.baseline.id,
            revision: revision,
            placement: placement
        )
        saved.pendingRun = submission
        guard await persist() else { saved.pendingRun = nil; return nil }
        return await submitRun(submission)
    }

    /// A retry repeats the same durable operation. It can never create a
    /// second run, even if the first answer was lost after the host accepted it.
    func retryRun() async -> TaskRunOutcome? {
        guard !working, let submission = saved.pendingRun else { return nil }
        return await submitRun(submission)
    }

    private func submitRun(_ submission: TaskRunSubmission) async -> TaskRunOutcome? {
        working = true
        defer { working = false }
        do {
            let outcome = try await runService.runTask(
                id: submission.cardID,
                revision: submission.revision,
                operationID: submission.operationID,
                placement: submission.placement
            )
            return await acceptRun(outcome, submission: submission)
        } catch {
            errorMessage = L10n.text("apple.taskeditorsession.the_run_result_is_not_confirmed_check_this.b7631660", "\(error.localizedDescription)")
            _ = await persist()
            return nil
        }
    }

    /// Receipt reads never launch work. They are safe during reopen and
    /// reconnect, while a resend remains an explicit person-owned action.
    func reconcileRun() async {
        guard !working, let submission = saved.pendingRun else { return }
        do {
            guard let outcome = try await runService.taskRunReceipt(operationID: submission.operationID) else {
                errorMessage = L10n.text("apple.taskeditorsession.the_computer_has_not_accepted_this_run_req.956da73e")
                return
            }
            _ = await acceptRun(outcome, submission: submission)
        } catch {
            errorMessage = L10n.text("apple.taskeditorsession.the_run_result_is_still_unavailable_your_r.294ee202", "\(error.localizedDescription)")
        }
    }

    private func acceptRun(_ outcome: TaskRunOutcome, submission: TaskRunSubmission) async -> TaskRunOutcome? {
        guard outcome.operationID == submission.operationID,
              outcome.cardID == submission.cardID else {
            errorMessage = L10n.text("apple.taskeditorsession.the_computer_returned_a_different_task_run.0580d53a")
            return nil
        }
        if outcome.run == nil, outcome.card == nil {
            saved.pendingRun = nil
            lastRun = outcome
            missing = true
            errorMessage = L10n.text("apple.taskeditorsession.this_task_was_deleted_before_the_request_c.291a0c1e")
            _ = await persist()
            return nil
        }
        if outcome.run == nil {
            lastRun = outcome
            errorMessage = L10n.text("apple.taskeditorsession.the_computer_accepted_this_request_but_has.582c4fe2")
            _ = await persist()
            return nil
        }
        if let card = outcome.card {
            saved.baseline = card
            current = card
            restoring = true
            fields = TaskEditorDraft(card)
            restoring = false
        }
        saved.pendingRun = nil
        lastRun = outcome
        if outcome.placement == .foreground, let ptyID = outcome.run?.ptyID, !ptyID.isEmpty {
            saved.liveTerminal = TaskLiveTerminal(runID: outcome.runID, ptyID: ptyID)
        } else {
            saved.liveTerminal = nil
        }
        errorMessage = nil
        _ = await persist()
        NotificationCenter.default.post(name: Self.didChange, object: target)
        return outcome
    }

    func stop() async {
        guard canStop, let revision = saved.baseline.revision,
              let delegate = saved.baseline.delegate else { return }
        working = true
        defer { working = false }
        do {
            let card = try await runService.stopTask(id: saved.baseline.id, revision: revision, runID: delegate.runId)
            saved.baseline = card
            current = card
            errorMessage = nil
            _ = await persist()
            NotificationCenter.default.post(name: Self.didChange, object: target)
        } catch {
            errorMessage = L10n.text("apple.taskeditorsession.the_stop_was_not_confirmed_reload_this_tas.ea360237", "\(error.localizedDescription)")
        }
    }

    func terminal(for outcome: TaskRunOutcome) async -> PtySessionInfo? {
        guard outcome.placement == .foreground, let ptyID = outcome.run?.ptyID, !ptyID.isEmpty else { return nil }
        return await attachTerminal(ptyID: ptyID)
    }

    /// Reopen the same host terminal for a live foreground run, including after
    /// the editor was dismissed. A background run has no terminal.
    func attachedTerminal() async -> PtySessionInfo? {
        guard let delegate = saved.baseline.delegate, delegate.isRunning else { return nil }
        if let outcome = lastRun, outcome.runID == delegate.runId {
            return await terminal(for: outcome)
        }
        guard let live = saved.liveTerminal, live.runID == delegate.runId else { return nil }
        return await attachTerminal(ptyID: live.ptyID)
    }

    private func attachTerminal(ptyID: String) async -> PtySessionInfo? {
        do { return try await runService.taskTerminal(ptyID: ptyID) }
        catch { errorMessage = error.localizedDescription; return nil }
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

    /// Keep the terminal identity only while the same foreground run is live.
    private func matchingLiveTerminal(_ card: TodoCard) -> TaskLiveTerminal? {
        guard let live = saved.liveTerminal,
              let delegate = card.delegate,
              delegate.isRunning,
              delegate.runId == live.runID else { return nil }
        return live
    }

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
