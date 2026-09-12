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
}
struct AgentBackend: Codable, Sendable {}
struct WorkspaceFolder: Codable, Sendable {}
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
actor FixtureTasks: TaskEditorService {
    var card: TodoCard? = TodoCard()
    var edits = 0
    var loseReply = false
    func supportsEditing() async -> Bool { true }
    func task(id: String) async throws -> TodoCard? { card }
    func taskBackends() async throws -> [AgentBackend] { [] }
    func taskFolders() async throws -> [WorkspaceFolder] { [] }
    func changeTitle(_ value: String) {
        let revision = (card?.revision ?? 0) + 1
        card?.title = value; card?.revision = revision
    }
    func disconnectAfterEdit() { loseReply = true }
    func delete() { card = nil }
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
}

@main struct TaskEditorSessionTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FixtureTasks()
        func session(host: String = "computer") -> TaskEditorSession {
            TaskEditorSession(target: TaskEditorTarget(peer: host), card: TodoCard(), scope: .local(installationID: "fixture"), hostIdentity: host, service: service, draftDirectory: directory)
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
        print("Task editing: exact budgets, durable drafts, host conflicts, lost-reply recovery, stale-window comparison and deletion preservation passed")
    }
}
