// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TaskEditorDraft.swift TaskEditorService.swift TaskEditorSession.swift
// WorkbenchDraftFile.swift OriginalFileCoordination.swift WorkReference.swift.
import Foundation

struct TodoCard: Codable, Sendable, Equatable {
    var id = "task"
    var revision: UInt64? = 1
    var title = "Review accessibility"
    var notes = "Check the editor"
    var workspaceID = "folder"
    var priority = "normal"
    var backend = "fixture"
    var model: String?
    var effort: String?
    var budgetSeconds: UInt64 = 121
    var delegate: TodoDelegate?
    var promptForRun: String {
        let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
struct TodoDelegate: Codable, Sendable, Equatable {
    var runId: String
    var status: String
    var isRunning: Bool { ["starting", "queued", "running", "stopping"].contains(status) }
}
enum TaskRunPlacement: String, Codable, Sendable, Equatable { case background, foreground }
struct RunRecord: Codable, Sendable {
    var id: String
    var workspaceID: String
    var ptyID: String?
}
struct PtySessionInfo: Codable, Sendable {}
struct TaskRunOutcome: Codable, Sendable {
    var operationID: String
    var cardID: String
    var runID: String
    var createdAtMs: Int64
    var placement: TaskRunPlacement
    var card: TodoCard?
    var run: RunRecord?
}
protocol TaskRunService: Sendable {
    func supportsTaskExecution() async -> Bool
    func runTask(id: String, revision: UInt64, operationID: String, placement: TaskRunPlacement) async throws -> TaskRunOutcome
    func taskRunReceipt(operationID: String) async throws -> TaskRunOutcome?
    func stopTask(id: String, revision: UInt64, runID: String) async throws -> TodoCard
    func taskTerminal(ptyID: String) async throws -> PtySessionInfo
}
extension TaskEditorTarget: TaskRunService {
    func supportsTaskExecution() async -> Bool { false }
    func runTask(id: String, revision: UInt64, operationID: String, placement: TaskRunPlacement) async throws -> TaskRunOutcome { throw FixtureError.unexpectedTransport }
    func taskRunReceipt(operationID: String) async throws -> TaskRunOutcome? { throw FixtureError.unexpectedTransport }
    func stopTask(id: String, revision: UInt64, runID: String) async throws -> TodoCard { throw FixtureError.unexpectedTransport }
    func taskTerminal(ptyID: String) async throws -> PtySessionInfo { throw FixtureError.unexpectedTransport }
}
struct AgentBackend: Codable, Sendable {}
struct WorkspaceFolder: Codable, Sendable {
    var id = ""
    var exists = true
}
enum FixtureError: Error { case disconnected, conflict, unexpectedTransport }
enum Bridge {
    static func onPeer<T: Decodable & Sendable>(_ peer: String, _ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
    static func localTaskEditor<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
}
enum RemoteHostFeature {
    case taskEditing
    func isSupported(peer: String?) async -> Bool { true }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}
actor FixtureTasks: TaskEditorService, TaskRunService {
    var card: TodoCard? = TodoCard()
    var edits = 0
    var loseReply = false
    var loseRunReply = false
    var failRunBeforeAcceptance = false
    var runAttempts: [TaskRunSubmission] = []
    var runOutcomes: [String: TaskRunOutcome] = [:]
    func supportsEditing() async -> Bool { true }
    func task(id: String) async throws -> TodoCard? { card }
    func taskBackends() async throws -> [AgentBackend] { [] }
    func taskFolders() async throws -> [WorkspaceFolder] { [] }
    func changeTitle(_ value: String) {
        let revision = (card?.revision ?? 0) + 1
        card?.title = value; card?.revision = revision
    }
    func disconnectAfterEdit() { loseReply = true }
    func setEditReplyLoss(_ value: Bool) { loseReply = value }
    func setRunFailure(before: Bool = false, after: Bool = false) {
        failRunBeforeAcceptance = before
        loseRunReply = after
    }
    func finishRun() { card?.delegate?.status = "ok" }
    func delete() { card = nil }
    func uncategorizedCard() -> TodoCard {
        var next = card ?? TodoCard()
        next.workspaceID = ""
        next.backend = ""
        card = next
        return next
    }
    func edit(id: String, revision: UInt64, draft: TaskEditorDraft) async throws -> TodoCard {
        guard var next = card, next.revision == revision else { throw FixtureError.conflict }
        edits += 1
        next.title = draft.title; next.notes = draft.prompt; next.workspaceID = draft.workspaceID
        next.priority = draft.priority; next.backend = draft.backend; next.model = draft.model
        next.effort = draft.effort; next.budgetSeconds = draft.budgetSeconds!
        next.revision = revision + 1
        card = next
        if loseReply { throw FixtureError.disconnected }
        return next
    }
    func supportsTaskExecution() async -> Bool { true }
    func runTask(id: String, revision: UInt64, operationID: String, placement: TaskRunPlacement) async throws -> TaskRunOutcome {
        let submission = TaskRunSubmission(operationID: operationID, cardID: id, revision: revision, placement: placement)
        runAttempts.append(submission)
        if failRunBeforeAcceptance { throw FixtureError.disconnected }
        if let outcome = runOutcomes[operationID] { return outcome }
        guard var next = card, next.id == id, next.revision == revision else { throw FixtureError.conflict }
        let runID = "run-\(operationID)"
        next.revision = revision + 1
        next.delegate = TodoDelegate(runId: runID, status: "running")
        card = next
        let outcome = TaskRunOutcome(
            operationID: operationID, cardID: id, runID: runID, createdAtMs: 1,
            placement: placement, card: next,
            run: RunRecord(id: runID, workspaceID: next.workspaceID, ptyID: placement == .foreground ? "pty" : nil)
        )
        runOutcomes[operationID] = outcome
        if loseRunReply { throw FixtureError.disconnected }
        return outcome
    }
    func taskRunReceipt(operationID: String) async throws -> TaskRunOutcome? { runOutcomes[operationID] }
    func stopTask(id: String, revision: UInt64, runID: String) async throws -> TodoCard {
        guard var next = card, next.id == id, next.revision == revision,
              next.delegate?.runId == runID else { throw FixtureError.conflict }
        next.revision = revision + 1
        next.delegate?.status = "stopping"
        card = next
        return next
    }
    func taskTerminal(ptyID: String) async throws -> PtySessionInfo {
        guard !ptyID.isEmpty else { throw FixtureError.disconnected }
        return PtySessionInfo()
    }
}

@main struct TaskEditorSessionTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FixtureTasks()
        func session(host: String = "computer") -> TaskEditorSession {
            TaskEditorSession(target: TaskEditorTarget(peer: host), card: TodoCard(), scope: .local(installationID: "fixture"), hostIdentity: host, service: service, runService: service, draftDirectory: directory)
        }
        let first = session()
        await first.load()
        assert(first.fields.budgetUnit == "seconds" && first.fields.budgetSeconds == 121)
        first.fields.budgetValue = "18446744073709551615"
        first.fields.budgetUnit = "minutes"
        assert(first.fields.validation != nil)
        first.fields.budgetValue = "121"; first.fields.budgetUnit = "seconds"
        first.fields.prompt = "My longer draft"
        await first.flush()
        let parallel = session()
        await parallel.load()
        let reopened = session()
        await reopened.load()
        assert(reopened.fields.prompt == "My longer draft")
        await service.changeTitle("Changed elsewhere")
        await reopened.refresh()
        assert(reopened.conflict && reopened.fields.title == "Review accessibility")
        await reopened.save()
        let before = await service.edits
        assert(before == 0)
        await reopened.resolveConflict(keepMine: true)
        await service.disconnectAfterEdit()
        await reopened.save()
        assert(reopened.saved.pending != nil)
        await reopened.save()
        let after = await service.edits
        assert(after == 1)
        parallel.fields.prompt = "Another window's draft"
        await parallel.flush()
        assert(parallel.otherDraft?.value.pending != nil)
        await parallel.resolveDiskConflict(keepMine: true)
        assert(parallel.otherDraft != nil, "A pending submission cannot be discarded by another window")
        await parallel.resolveDiskConflict(keepMine: false)
        assert(parallel.saved.pending == nil && !parallel.dirty)
        let recovered = session()
        await recovered.load()
        assert(recovered.saved.pending == nil && !recovered.dirty)
        let recoveryCount = await service.edits
        assert(recoveryCount == 1, "Read-only recovery must not repeat an edit")
        await service.setEditReplyLoss(false)
        await service.setRunFailure(after: true)
        _ = await recovered.run(.background)
        let acceptedSubmission = recovered.saved.pendingRun!
        let firstRunCount = await service.runAttempts.count
        assert(firstRunCount == 1)
        await recovered.reconcileRun()
        assert(recovered.saved.pendingRun == nil && recovered.lastRun?.operationID == acceptedSubmission.operationID)
        assert(!recovered.canRun, "An active linked run must disable another launch")
        let recoveredRunCount = await service.runAttempts.count
        assert(recoveredRunCount == 1, "Receipt recovery must not submit a second run")
        recovered.fields.prompt = "Editing while it runs"
        assert(recovered.canStop, "A dirty draft must not disable Stop")
        assert(recovered.saved.liveTerminal == nil, "A background run has no terminal to reopen")
        recovered.fields.prompt = "My longer draft"
        await recovered.stop()
        assert(recovered.saved.baseline.delegate?.status == "stopping" && !recovered.canStop)

        await service.finishRun()
        await service.setRunFailure(before: true)
        let retrying = session(host: "run-retry")
        await retrying.load()
        _ = await retrying.run(.foreground)
        let retrySubmission = retrying.saved.pendingRun!
        await retrying.reconcileRun()
        assert(retrying.saved.pendingRun == retrySubmission)
        let retryReopened = session(host: "run-retry")
        await retryReopened.load()
        assert(retryReopened.saved.pendingRun == retrySubmission)
        let attemptsBeforeExplicitRetry = await service.runAttempts.count
        assert(attemptsBeforeExplicitRetry == 2, "Reopening and checking must not resubmit an unaccepted run")
        await service.setRunFailure()
        _ = await retryReopened.retryRun()
        let attempts = await service.runAttempts
        assert(attempts.suffix(2).allSatisfy { $0 == retrySubmission }, "Explicit retry keeps the original operation and placement")
        await retryReopened.reconcileRun()
        assert(retryReopened.saved.liveTerminal?.ptyID == "pty")
        let reopenedTerminal = await retryReopened.attachedTerminal()
        assert(reopenedTerminal != nil, "A live foreground run must reopen its terminal")
        let restored = session(host: "run-retry")
        await restored.load()
        assert(restored.lastRun == nil, "A relaunched editor has no in-memory run")
        assert(restored.saved.liveTerminal?.ptyID == "pty")
        let restoredTerminal = await restored.attachedTerminal()
        assert(restoredTerminal != nil, "A relaunched editor must reopen the same live terminal")
        first.fields.prompt = "Older window writing"
        await first.flush()
        assert(first.otherDraft != nil && first.fields.prompt == "Older window writing")
        await first.resolveDiskConflict(keepMine: false)
        assert(first.fields.prompt == "My longer draft")
        await service.delete()
        recovered.fields.prompt = "Keep after deletion"
        await recovered.refresh()
        assert(recovered.missing && !recovered.canSave && recovered.fields.prompt == "Keep after deletion")
        let other = session(host: "other-computer")
        await other.load()
        assert(other.fields.prompt == "Check the editor")
        await recovered.flush()
        let unavailable = directory.appendingPathComponent("unavailable")
        try Data("fixture".utf8).write(to: unavailable)
        let blockedService = FixtureTasks()
        let blocked = TaskEditorSession(target: TaskEditorTarget(peer: "blocked"), card: TodoCard(),
                                        scope: .local(installationID: "fixture"), hostIdentity: "blocked",
                                        service: blockedService, draftDirectory: unavailable)
        await blocked.load()
        blocked.fields.prompt = "Keep this writing when storage fails"
        await blocked.save()
        let blockedCount = await blockedService.edits
        assert(blockedCount == 0 && blocked.errorMessage != nil)
        assert(blocked.fields.prompt == "Keep this writing when storage fails")
        let gapDir = directory.appendingPathComponent("uncategorized")
        try FileManager.default.createDirectory(at: gapDir, withIntermediateDirectories: true)
        let gapService = FixtureTasks()
        let gapCard = await gapService.uncategorizedCard()
        let gap = TaskEditorSession(
            target: TaskEditorTarget(peer: "gap"), card: gapCard,
            scope: .local(installationID: "fixture"), hostIdentity: "gap",
            service: gapService, runService: gapService, draftDirectory: gapDir
        )
        await gap.load()
        assert(!gap.canRun)
        assert(gap.runReadiness?.contains("folder") == true, "An uncategorized task must not pretend it can run")
        // Drafts written before the id keys were renamed still decode, and a
        // fresh encode uses the new spelling, so an in-flight run survives.
        let legacySubmission = try JSONDecoder().decode(TaskRunSubmission.self, from: Data(
            #"{"operationID":"op","cardID":"card","revision":3,"placement":"background"}"#.utf8))
        assert(legacySubmission.operationID == "op" && legacySubmission.cardID == "card")
        let newSubmission = try JSONDecoder().decode(TaskRunSubmission.self, from: Data(
            #"{"operationId":"op","cardId":"card","revision":3,"placement":"background"}"#.utf8))
        assert(newSubmission == legacySubmission)
        let encoded = try JSONEncoder().encode(newSubmission)
        assert(String(data: encoded, encoding: .utf8)?.contains("operationId") == true)
        assert(String(data: encoded, encoding: .utf8)?.contains("operationID") == false)
        let legacyTerminal = try JSONDecoder().decode(TaskLiveTerminal.self, from: Data(
            #"{"runID":"run","ptyID":"pty"}"#.utf8))
        assert(legacyTerminal.runID == "run" && legacyTerminal.ptyID == "pty")
        let newTerminal = try JSONDecoder().decode(TaskLiveTerminal.self, from: Data(
            #"{"runId":"run","ptyId":"pty"}"#.utf8))
        assert(newTerminal == legacyTerminal)
        print("Task editing: exact budgets, durable drafts, host conflicts, lost-reply recovery, stale-window comparison and deletion preservation passed")
    }
}
