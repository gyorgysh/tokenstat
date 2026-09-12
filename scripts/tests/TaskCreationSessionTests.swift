// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TaskEditorDraft.swift TaskEditorService.swift TaskCreationService.swift TaskCreationSession.swift
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
}
struct AgentBackend: Codable, Sendable {}
struct WorkspaceFolder: Codable, Sendable {}
enum FixtureError: Error { case disconnected, conflict, unexpectedTransport }
enum Bridge {
    static func peerProtocolVersion(_ peer: String) async throws -> Int { 19 }
    static func onPeer<T: Decodable & Sendable>(_ peer: String, _ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
    static func localTaskEditor<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
}
enum RemoteHostFeature {
    case taskEditing, taskCreation
    var minimumProtocol: Int { 19 }
    func isSupported(peer: String?) async -> Bool { true }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}
struct AutomationQueue: Codable, Sendable { let defaultBudgetSeconds: UInt64 }
enum TaskEditorSession { static let didChange = Notification.Name("fixture.taskDidChange") }

actor FixtureCreation: TaskCreationService {
    var budget: UInt64 = 121
    var offline = false
    var supported = true
    var attempts: [TaskCreationSubmission] = []
    var outcomes: [String: TaskCreationOutcome] = [:]
    var failBeforeCreation = false
    var loseReply = false
    func supportsCreation() async -> Bool { supported }
    func setSupported(_ value: Bool) { supported = value }
    func creationDefaults() async throws -> UInt64 { if offline { throw FixtureError.disconnected }; return budget }
    func setOffline(_ value: Bool) { offline = value }
    func creationBackends() async throws -> [AgentBackend] { [] }
    func creationFolders() async throws -> [WorkspaceFolder] { [] }
    func setBudget(_ value: UInt64) { budget = value }
    func setFailure(before: Bool = false, after: Bool = false) { failBeforeCreation = before; loseReply = after }
    func createTask(_ submission: TaskCreationSubmission) async throws -> TaskCreationOutcome {
        attempts.append(submission)
        if failBeforeCreation { throw FixtureError.disconnected }
        if let saved = outcomes[submission.operationID] { return saved }
        var card = TodoCard()
        card.title = submission.fields.title; card.notes = submission.fields.prompt
        card.workspaceID = submission.fields.workspaceID; card.budgetSeconds = submission.fields.budgetSeconds!
        let outcome = TaskCreationOutcome(operationID: submission.operationID, cardID: card.id, createdAtMs: 1, card: card)
        outcomes[submission.operationID] = outcome
        if loseReply { throw FixtureError.disconnected }
        return outcome
    }
    func taskCreationReceipt(operationID: String) async throws -> TaskCreationOutcome? { outcomes[operationID] }
    func delete(_ id: String) {
        let old = outcomes[id]!
        outcomes[id] = TaskCreationOutcome(operationID: id, cardID: old.cardID, createdAtMs: old.createdAtMs, card: nil)
    }
}

@main struct TaskCreationSessionTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FixtureCreation()
        func session(host: String = "computer", folder: String = "folder") -> TaskCreationSession {
            TaskCreationSession(target: TaskEditorTarget(peer: host), workspaceID: folder, column: "backlog",
                                scope: .local(installationID: "fixture"), hostIdentity: host, service: service, draftDirectory: directory)
        }
        let first = session()
        await first.load()
        assert(first.fields.budgetSeconds == 121 && first.fields.budgetUnit == "seconds")
        first.fields.title = "New task"; first.fields.prompt = "Detailed instructions"
        await first.flush()
        await service.setBudget(600)
        let reopened = session()
        await reopened.load()
        assert(reopened.fields.prompt == "Detailed instructions" && reopened.fields.budgetSeconds == 121)
        await service.setFailure(after: true)
        let firstTap = Task { await reopened.create() }
        let repeatedTap = Task { await reopened.create() }
        await firstTap.value; await repeatedTap.value
        let operation = reopened.saved.pending!.operationID
        assert(reopened.saved.outcome == nil && !reopened.canEdit)
        await reopened.create()
        let sent = await service.attempts
        assert(sent.count == 1)
        await service.delete(operation)
        let recovered = session()
        await recovered.load()
        assert(recovered.saved.outcome?.operationID == operation && recovered.saved.outcome?.card == nil)
        let recoveredCount = await service.attempts.count
        assert(recoveredCount == 1, "Recovery must not recreate a deleted task")
        let cleared = await recovered.finish(operationID: operation)
        assert(cleared && recovered.fields.title.isEmpty && recovered.fields.budgetSeconds == 600)
        recovered.fields.title = "Next task"
        await recovered.flush()
        let staleFinish = await recovered.finish(operationID: operation)
        assert(!staleFinish && recovered.fields.title == "Next task")

        let retry = session(host: "retry")
        await retry.load(); retry.fields.title = "Retry this exact task"
        await service.setFailure(before: true)
        await retry.create()
        let pending = retry.saved.pending!
        await retry.check()
        assert(retry.canRetry)
        await service.setBudget(0)
        await service.setFailure()
        await retry.retry()
        assert(retry.saved.outcome != nil)
        let attempts = await service.attempts
        assert(attempts.suffix(2).allSatisfy { $0 == pending }, "Retry keeps identity and exact budget")

        let owner = session(host: "parallel")
        await owner.load(); owner.fields.title = "Owner draft"; await owner.flush()
        let other = session(host: "parallel")
        await other.load()
        await service.setFailure(before: true)
        await owner.create()
        other.fields.title = "Other writing"; await other.flush()
        assert(other.otherDraft?.value.pending != nil)
        await other.resolveDiskConflict(keepMine: true)
        assert(other.otherDraft != nil)
        await other.resolveDiskConflict(keepMine: false)
        assert(other.saved.pending == owner.saved.pending)
        let isolated = session(host: "isolated")
        await isolated.load()
        assert(isolated.fields.title.isEmpty && isolated.fields.noTimeLimit)
        let differentFolder = session(host: "parallel", folder: "different")
        await differentFolder.load()
        assert(differentFolder.fields.title.isEmpty)

        await service.setOffline(true)
        let offline = session(host: "offline")
        await offline.load()
        assert(offline.canEdit && !offline.canCreate && offline.saved.needsDefault)
        offline.fields.title = "Captured offline"; offline.fields.prompt = "Keep this writing"
        await offline.flush()
        let offlineReopened = session(host: "offline")
        await service.setOffline(false); await service.setBudget(91)
        await offlineReopened.load()
        assert(offlineReopened.fields.title == "Captured offline" && offlineReopened.fields.budgetSeconds == 91)
        assert(offlineReopened.canCreate && !offlineReopened.saved.needsDefault)

        await service.setSupported(false)
        let oldHost = session(host: "old-host")
        await oldHost.load(); oldHost.fields.title = "Keep for a newer host"
        await oldHost.flush()
        assert(oldHost.canEdit && !oldHost.canCreate && oldHost.errorMessage?.contains("Update") == true)
        let beforeOldHost = await service.attempts.count
        await oldHost.create()
        let afterOldHost = await service.attempts.count
        assert(beforeOldHost == afterOldHost)
        await service.setSupported(true); await oldHost.load()
        assert(oldHost.canCreate && oldHost.fields.title == "Keep for a newer host")

        let blocked = session(host: "blocked")
        await blocked.load()
        blocked.fields.title = "Cannot persist"
        // Make the draft directory unavailable after loading, before submission.
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        let before = await service.attempts.count
        await blocked.create()
        let after = await service.attempts.count
        assert(before == after && blocked.saved.pending == nil && blocked.errorMessage != nil)
        print("Task creation draft, default, receipt, deletion, retry and isolation tests passed")
    }
}
