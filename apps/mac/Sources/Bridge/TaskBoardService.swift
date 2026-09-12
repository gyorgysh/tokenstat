// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct TaskBoardCapabilities: Sendable, Equatable {
    let edit: Bool
    let delete: Bool
}

protocol TaskBoardService: Sendable {
    func boardCapabilities() async -> TaskBoardCapabilities
    func boardCards() async throws -> [TodoCard]
    func boardFolders() async throws -> [WorkspaceFolder]
    func boardBackends() async throws -> [AgentBackend]
    func moveTask(_ card: TodoCard, column: String, order: Int64?) async throws -> TodoCard
    func deleteTask(_ card: TodoCard) async throws
}

extension TaskEditorTarget: TaskBoardService {
    func boardCapabilities() async -> TaskBoardCapabilities {
        let editing = await supportsEditing()
        let deletion = await RemoteHostFeature.taskDeletion.isSupported(peer: peer)
        return TaskBoardCapabilities(edit: editing, delete: deletion)
    }
    func boardCards() async throws -> [TodoCard] { try await call("todo.list", ["includeArchived": true], as: [TodoCard].self) }
    func boardFolders() async throws -> [WorkspaceFolder] { try await taskFolders() }
    func boardBackends() async throws -> [AgentBackend] { try await taskBackends() }
    func moveTask(_ card: TodoCard, column: String, order: Int64?) async throws -> TodoCard {
        guard await supportsEditing(), let revision = card.revision else {
            throw TaskEditorDraft.Invalid.fields("Update this computer's tokenstat to move tasks safely from here.")
        }
        var params: [String: Any] = ["id": card.id, "expectedRevision": revision, "column": column]
        if let order { params["order"] = order }
        return try await call("todo.edit", params, as: TodoCard.self)
    }
    func deleteTask(_ card: TodoCard) async throws {
        guard await RemoteHostFeature.taskDeletion.isSupported(peer: peer), let revision = card.revision else {
            throw TaskEditorDraft.Invalid.fields("Update this computer's tokenstat to delete the reviewed task safely.")
        }
        let _: TaskBoardRemoval = try await call("todo.delete", ["id": card.id, "expectedRevision": revision], as: TaskBoardRemoval.self)
    }
}

private struct TaskBoardRemoval: Decodable, Sendable { let removed: Bool }
