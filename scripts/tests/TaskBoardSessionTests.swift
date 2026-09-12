// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TaskBoardFilter.swift TaskBoardSession.swift WorkReference.swift.
import Foundation

struct TodoDelegate: Sendable { var status: String; var isRunning: Bool { status == "running" || status == "queued" } }
struct TodoCard: Sendable {
    var id: String
    var title = "Task"
    var notes = "Prompt"
    var workspaceID = "folder"
    var column = "backlog"
    var backend = "codex"
    var priority = "normal"
    var order: Int64 = 0
    var createdAtMs: Int64 = 0
    var isNote = false
    var delegate: TodoDelegate?
}
struct WorkspaceFolder: Sendable {}
struct AgentBackend: Sendable {}
enum FixtureError: Error { case unexpectedTransport }
struct TaskBoardCapabilities: Sendable, Equatable { let edit: Bool; let delete: Bool }
protocol TaskBoardService: Sendable {
    func boardCapabilities() async -> TaskBoardCapabilities
    func boardCards() async throws -> [TodoCard]
    func boardFolders() async throws -> [WorkspaceFolder]
    func boardBackends() async throws -> [AgentBackend]
    func moveTask(_ card: TodoCard, column: String, order: Int64?) async throws -> TodoCard
    func deleteTask(_ card: TodoCard) async throws
}
extension TaskBoardService {
    func boardCapabilities() async -> TaskBoardCapabilities { TaskBoardCapabilities(edit: true, delete: true) }
}
struct TaskEditorTarget: Hashable, Sendable, TaskBoardService {
    let peer: String?
    func boardCards() async throws -> [TodoCard] { throw FixtureError.unexpectedTransport }
    func boardFolders() async throws -> [WorkspaceFolder] { [] }
    func boardBackends() async throws -> [AgentBackend] { [] }
    func moveTask(_ card: TodoCard, column: String, order: Int64?) async throws -> TodoCard { throw FixtureError.unexpectedTransport }
    func deleteTask(_ card: TodoCard) async throws { throw FixtureError.unexpectedTransport }
}
enum TaskEditorSession { static let didChange = Notification.Name("fixture.taskChanged") }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}
actor FixtureBoard: TaskBoardService {
    var cards: [TodoCard]
    var moves: [(String, String, Int64?)] = []
    var paused = false
    var pending: CheckedContinuation<[TodoCard], Never>?
    var moving: CheckedContinuation<Void, Never>?
    var pauseMoves = false
    init(_ cards: [TodoCard]) { self.cards = cards }
    func boardCards() async throws -> [TodoCard] {
        if paused { paused = false; return await withCheckedContinuation { pending = $0 } }
        return cards
    }
    func boardFolders() async throws -> [WorkspaceFolder] { [] }
    func boardBackends() async throws -> [AgentBackend] { [] }
    func pauseNextRead() { paused = true }
    func releaseOldRead(_ value: [TodoCard]) { pending?.resume(returning: value); pending = nil }
    func set(_ value: [TodoCard]) { cards = value }
    func pauseNextMove() { pauseMoves = true }
    func resumeMove() { moving?.resume(); moving = nil }
    func moveTask(_ card: TodoCard, column: String, order: Int64?) async throws -> TodoCard {
        moves.append((card.id, column, order))
        if pauseMoves { pauseMoves = false; await withCheckedContinuation { moving = $0 } }
        return card
    }
    func deleteTask(_ card: TodoCard) async throws { cards.removeAll { $0.id == card.id } }
}

@main struct TaskBoardSessionTests {
    @MainActor static func main() async throws {
        let a = TodoCard(id: "a", title: "Review keyboard", notes: "Use the theme", order: 0)
        let hidden = TodoCard(id: "hidden", workspaceID: "other", order: 1)
        let b = TodoCard(id: "b", title: "Write docs", order: 2)
        let note = TodoCard(id: "note", order: 3, isNote: true)
        let c = TodoCard(id: "c", priority: "high", order: 4, delegate: TodoDelegate(status: "error"))
        let archived = TodoCard(id: "archive", column: "archive")
        let unfiled = TodoCard(id: "unfiled", workspaceID: "")
        let cards = [a, hidden, b, note, c, archived, unfiled]
        var filter = TaskBoardFilter(folder: .folder("folder"))
        assert(filter.cards(from: [TodoCard(id: "z"), TodoCard(id: "a")]).map(\.id) == ["z", "a"], "Equal order values retain the host's order")
        assert(filter.cards(from: cards).map(\.id) == ["a", "b", "c"])
        filter.query = "KEYBOARD theme"
        assert(filter.cards(from: cards).map(\.id) == ["a"])
        filter.query = ""; filter.attention = .needsAttention
        assert(filter.cards(from: cards).map(\.id) == ["c"])
        filter.attention = .all; filter.folder = .uncategorized
        assert(filter.cards(from: cards).map(\.id) == ["unfiled"])
        filter.folder = .all; filter.archived = true
        assert(filter.cards(from: cards).map(\.id) == ["archive"])

        let service = FixtureBoard(cards)
        let target = TaskEditorTarget(peer: "computer")
        let session = TaskBoardSession(target: target, folder: "folder", service: service)
        await session.load()
        await session.move(c, to: "backlog", before: b.id)
        let move = await service.moves.last!
        assert(move.2 == 3, "Reorder must include hidden folders and notes in the host's column order")
        // unfiled shares order zero in this fixture; it also occupies a slot.
        await service.pauseNextRead()
        let old = Task { await session.load() }
        while await service.pending == nil { await Task.yield() }
        await service.set([b])
        await session.load()
        await service.releaseOldRead(cards)
        await old.value
        assert(session.cards.map(\.id) == ["b"], "An older read cannot overwrite the refreshed board")
        await service.pauseNextMove()
        let moving = Task { await session.move(b, to: "done") }
        while await service.moving == nil { await Task.yield() }
        let count = await service.moves.count
        await session.move(b, to: "done")
        let after = await service.moves.count
        assert(count == after, "Repeated taps must not send another mutation")
        await service.resumeMove()
        await moving.value
        await session.delete(b)
        assert(session.cards.isEmpty)

        WorkSessionContext.shared.scope = .local(installationID: "first")
        let retained = TaskBoardSessions.session(target: target, folder: nil)
        retained.filter.query = "Keep on resize"
        assert(TaskBoardSessions.session(target: target, folder: nil) === retained)
        assert(TaskBoardSessions.session(target: target, folder: "") !== retained)
        WorkSessionContext.shared.scope = .local(installationID: "second")
        assert(TaskBoardSessions.session(target: target, folder: nil) !== retained)
        print("Task board: filtering, scoped ownership, host-relative ordering, stale-read rejection and duplicate-tap protection passed")
    }
}
